//
//  DownloadManager.swift
//  Nugget
//
//  Created on 19/07/2026.
//

import AVFoundation
import Combine
import Foundation
import GRDB
import Network
import Nuke
import SwiftUI
import UIKit
import ffmpegkit

@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var downloads: [String: DownloadState] = [:]
    @Published private(set) var tracks: [DownloadedTrackEntity] = []
    @Published private(set) var persistedDownloadCount = 0
    @Published private(set) var isLoaded = false

    enum DownloadState: Equatable {
        case notStarted
        case downloading(Double)
        case completed
        case failed(String)
    }

    private static let minimumAudioBytes = 8_192
    private static let preferredMinArtworkDimension: CGFloat = 480

    private let fileManager = FileManager.default
    private let pathMonitor = NWPathMonitor()
    private var currentPath: NWPath?
    private var isReloading = false
    private var isMutatingLibrary = false
    private var cancelledDownloadIds: Set<String> = []
    private var lastReportedProgress: [String: Double] = [:]
    private var activeFFmpegSessions: [String: FFmpegSession] = [:]

    private var downloadQueue: [SongItem] = []
    private var queuedIds: Set<String> = []
    private var isProcessingQueue = false

    private var tracksById: [String: DownloadedTrackEntity] = [:]

    private var downloadsDir: URL {
        let base = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("Downloads", isDirectory: true)
    }

    private init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.currentPath = path
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.nugget.network"))

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.reload()
            }
        }

        Task { await reload() }
    }

    private var isOnWiFi: Bool {
        guard let currentPath else { return true }
        return currentPath.usesInterfaceType(.wifi) == true
            || currentPath.usesInterfaceType(.wiredEthernet) == true
    }

    // MARK: - Sequential Bulk Queue & Removals

    func enqueueDownloads(songs: [SongItem]) {
        for song in songs where !queuedIds.contains(song.videoId) {
            if state(for: song.videoId) == .completed { continue }
            if case .downloading = downloads[song.videoId] { continue }
            queuedIds.insert(song.videoId)
            downloadQueue.append(song)
        }
        guard !isProcessingQueue else { return }
        Task { await drainDownloadQueue() }
    }

    private func drainDownloadQueue() async {
        guard !isProcessingQueue else { return }
        isProcessingQueue = true
        defer { isProcessingQueue = false }

        while !downloadQueue.isEmpty {
            let next = downloadQueue.removeFirst()
            queuedIds.remove(next.videoId)
            await download(song: next)
        }
    }

    func removeDownloads(videoIds: [String]) async {
        guard !videoIds.isEmpty else { return }
        let uniqueIds = Array(Set(videoIds))

        for id in uniqueIds {
            queuedIds.remove(id)
            downloadQueue.removeAll { $0.videoId == id }
            cancelledDownloadIds.insert(id)
            if let session = activeFFmpegSessions.removeValue(forKey: id) {
                session.cancel()
            }
            lastReportedProgress.removeValue(forKey: id)
            downloads[id] = .notStarted
            tracksById.removeValue(forKey: id)
        }
        apply(tracksById)

        let dirURL = downloadsDir
        let fm = fileManager
        await Task.detached(priority: .utility) {
            let urls = (try? fm.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            let idSet = Set(uniqueIds)
            for url in urls where url.pathExtension.lowercased() == "m4a" {
                if let vid = Self.videoId(from: url.lastPathComponent), idSet.contains(vid) {
                    try? fm.removeItem(at: url)
                }
            }
        }.value

        try? await DatabaseService.shared.write { db in
            for chunk in DatabaseService.chunked(uniqueIds) {
                let placeholders = DatabaseService.placeholders(count: chunk.count)
                try db.execute(
                    sql: "DELETE FROM downloaded_track WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(chunk)
                )
            }
        }
    }

    // MARK: - Paths

    func fileURL(for song: SongItem) async -> URL {
        await displayDestinationURL(
            title: song.title,
            artist: song.artists.map(\.name).joined(separator: ", "),
            videoId: song.videoId
        )
    }

    func displayDestinationURL(title: String, artist: String, videoId: String) async -> URL {
        ensureDirectories()
        let rawStem = title.isEmpty ? videoId : (artist.isEmpty ? title : "\(artist) - \(title)")
        let stem = Self.sanitizeFileName(rawStem)
        return downloadsDir.appendingPathComponent("\(stem) [\(videoId)].m4a")
    }

    nonisolated static func sanitizeFileName(_ name: String) -> String {
        var stem = name.replacingOccurrences(of: "/", with: "-")
        let illegal = CharacterSet(charactersIn: ":\\?%*|\"<>").union(.controlCharacters)
        stem = stem.components(separatedBy: illegal).joined(separator: "-")
        stem = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        while stem.utf8.count > 150 { stem = String(stem.dropLast()) }
        stem = stem.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return stem.isEmpty ? "Untitled" : stem
    }

    nonisolated static func transcodeBitrate(for quality: DownloadQuality) -> Int {
        switch quality {
        case .aac256: return 256_000
        case .auto, .high: return 192_000
        case .standard: return 96_000
        }
    }

    @discardableResult
    func ensureDirectories() -> Bool {
        try? fileManager.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        return true
    }

    private func resolvedURL(for track: DownloadedTrackEntity) -> URL? {
        let stored = track.localPath
        let url: URL
        if stored.hasPrefix("/") {
            url = URL(fileURLWithPath: stored)
        } else {
            url = downloadsDir.appendingPathComponent(stored)
        }
        if fileManager.fileExists(atPath: url.path) { return url }

        let fileName = (stored as NSString).lastPathComponent
        if !fileName.isEmpty {
            let byName = downloadsDir.appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: byName.path) { return byName }
        }

        return nil
    }

    private func storedPath(for url: URL) -> String {
        url.lastPathComponent
    }

    // MARK: - Reload / reconciliation

    func reload() async {
        guard !isReloading else { return }
        isReloading = true
        defer { isReloading = false }

        ensureDirectories()
        let scanned = scanDownloadedFiles()

        var rebuilt: [String: DownloadedTrackEntity] = [:]
        let databaseTracks = await fetchAllFromDatabase()

        for track in databaseTracks {
            guard let url = resolvedURL(for: track) ?? scanned[track.id] else {
                _ = try? await DatabaseService.shared.delete(track)
                continue
            }
            var fixed = track
            fixed.localPath = storedPath(for: url)
            if fixed.localPath != track.localPath {
                try? await DatabaseService.shared.save(fixed)
            }
            rebuilt[fixed.id] = fixed
        }

        for (videoId, url) in scanned where rebuilt[videoId] == nil {
            let metadata = await songMetadata(for: videoId)
            let audioMeta = await extractAudioMetadata(from: url)
            let entity = DownloadedTrackEntity(
                id: videoId,
                title: metadata?.title ?? Self.displayTitle(from: url),
                artist: metadata?.artistName ?? "",
                duration: metadata?.duration ?? 0,
                thumbnailUrl: Self.bestStoredThumbnailUrl(metadata?.thumbnailUrl, videoId: videoId),
                localPath: storedPath(for: url),
                downloadedAt: (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? Date(),
                itag: audioMeta.itag,
                codec: audioMeta.codec,
                bitrate: audioMeta.bitrate
            )
            _ = try? await DatabaseService.shared.insertOrReplace(entity)
            rebuilt[videoId] = entity
            Log.downloadManager.notice("Recovered orphaned download \(videoId) from \(url.lastPathComponent)")
        }

        apply(rebuilt)
        isLoaded = true
    }

    func reconcileDownloadedFiles() async {
        await reload()
    }

    private func apply(_ newTracks: [String: DownloadedTrackEntity]) {
        tracksById = newTracks
        let sorted = newTracks.values.sorted { $0.downloadedAt > $1.downloadedAt }
        if tracks != sorted { tracks = sorted }
        if persistedDownloadCount != newTracks.count { persistedDownloadCount = newTracks.count }
    }

    private func scanDownloadedFiles() -> [String: URL] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: downloadsDir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        var found: [String: URL] = [:]
        var dates: [String: Date] = [:]

        for url in urls where url.pathExtension.lowercased() == "m4a" {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard (values?.fileSize ?? 0) >= Self.minimumAudioBytes else { continue }
            guard let videoId = Self.videoId(from: url.lastPathComponent) else { continue }
            let modified = values?.contentModificationDate ?? .distantPast
            if let existingDate = dates[videoId], existingDate >= modified { continue }
            found[videoId] = url
            dates[videoId] = modified
        }
        return found
    }

    nonisolated static func videoId(from fileName: String) -> String? {
        let base = (fileName as NSString).deletingPathExtension
        guard let range = base.range(of: #"\[([A-Za-z0-9_-]{6,})\]$"#, options: .regularExpression) else {
            return nil
        }
        let bracketed = base[range]
        return bracketed.dropFirst().dropLast().description
    }

    nonisolated private static func displayTitle(from url: URL) -> String {
        var base = (url.lastPathComponent as NSString).deletingPathExtension
        if let range = base.range(of: #"\s*\[[A-Za-z0-9_-]{6,}\]$"#, options: .regularExpression) {
            base.removeSubrange(range)
        }
        return base.isEmpty ? url.lastPathComponent : base
    }

    nonisolated private static func bestStoredThumbnailUrl(_ rawUrl: String?, videoId: String) -> String? {
        if let rawUrl, !rawUrl.isEmpty {
            if let upgraded = ArtworkURLs.highRes(rawUrl) {
                return upgraded
            }
            return rawUrl
        }
        return ArtworkURLs.fallback(for: videoId)
    }

    private func songMetadata(for videoId: String) async -> SongEntity? {
        try? await DatabaseService.shared.fetchOne(SongEntity.self, key: videoId)
    }
}

// MARK: - Download

extension DownloadManager {

    func download(song: SongItem) async {
        let videoId = song.videoId
        if case .downloading = downloads[videoId] {
            Log.downloadManager.debug("Download already in progress for \(videoId)")
            return
        }

        if let existing = await localURL(for: videoId),
           let size = try? existing.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size >= Self.minimumAudioBytes {
            downloads[videoId] = .completed
            if tracksById[videoId] == nil {
                await adoptExistingFile(at: existing, song: song)
            }
            return
        }

        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "nugget-download-\(videoId)") {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
        defer {
            if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
        }

        cancelledDownloadIds.remove(videoId)
        lastReportedProgress.removeValue(forKey: videoId)
        let artist = song.artists.map(\.name).joined(separator: ", ")
        let downloadStart = CFAbsoluteTimeGetCurrent()
        Log.downloadManager.debug("Starting download: \(artist) - \(song.title) (\(videoId))")

        if SettingsStore.shared.wifiOnlyDownloads, !isOnWiFi {
            downloads[videoId] = .failed("Wi-Fi Only is enabled and you are not on Wi-Fi.")
            return
        }

        setProgress(0.02, for: videoId)

        let fileURL = await fileURL(for: song)
        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                try? fileManager.removeItem(at: fileURL)
            }

            async let artworkData = prefetchArtwork(from: song.thumbnailUrl, videoId: videoId)

            setProgress(0.05, for: videoId)
            let resolveStart = CFAbsoluteTimeGetCurrent()
            let result = try await PlaybackManager.shared.resolve(
                videoId: videoId,
                forDownload: true
            )
            let resolveElapsed = CFAbsoluteTimeGetCurrent() - resolveStart
            let streamURL = result.streamUrl
            let isAACStream = result.mimeType.lowercased().contains("mp4a")
                || result.mimeType.lowercased().contains("aac")
            Log.downloadManager.debug("RESOLVE \(String(format: "%.1f", resolveElapsed))s codec=\(result.mimeType) isAAC=\(isAACStream)")

            guard let url = URL(string: streamURL) else {
                throw DownloadError.invalidStreamURL
            }

            let tempDownload = fileManager.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).\(isAACStream ? "m4a" : "webm")")
            defer { try? fileManager.removeItem(at: tempDownload) }
            let dlStart = CFAbsoluteTimeGetCurrent()
            try await downloadToFile(
                from: url,
                to: tempDownload,
                videoId: videoId,
                userAgent: result.userAgent,
                clientName: result.clientName
            )
            let dlElapsed = CFAbsoluteTimeGetCurrent() - dlStart
            let dlSize = (try? tempDownload.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            Log.downloadManager.debug("DOWNLOAD \(String(format: "%.1f", dlElapsed))s \(dlSize / 1024)KB")

            let artwork = await artworkData

            ensureDirectories()
            setProgress(0.88, for: videoId)
            let ffmpegStart = CFAbsoluteTimeGetCurrent()
            if isAACStream {
                let validateStart = CFAbsoluteTimeGetCurrent()
                try await validateDownloadedFile(at: tempDownload)
                Log.downloadManager.debug("VALIDATE \(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - validateStart))s")

                Log.downloadManager.debug("FFMPEG remux (AAC passthrough)...")
                try await attachMetadata(
                    to: tempDownload,
                    title: song.title,
                    artist: artist,
                    artworkData: artwork,
                    videoId: videoId
                )
                try fileManager.moveItem(at: tempDownload, to: fileURL)
            } else {
                Log.downloadManager.debug("FFMPEG transcode (Opus -> AAC)...")
                try await processAudio(
                    TranscodeRequest(
                        inputURL: tempDownload,
                        outputURL: fileURL,
                        title: song.title,
                        artist: artist,
                        artworkData: artwork
                    ),
                    videoId: videoId
                )
                let validateStart = CFAbsoluteTimeGetCurrent()
                do {
                    try await validateDownloadedFile(at: fileURL)
                } catch {
                    try? fileManager.removeItem(at: fileURL)
                    throw error
                }
                Log.downloadManager.debug("VALIDATE \(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - validateStart))s")
            }
            Log.downloadManager.debug("FFMPEG \(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - ffmpegStart))s")

            if cancelledDownloadIds.contains(videoId) {
                cancelledDownloadIds.remove(videoId)
                lastReportedProgress.removeValue(forKey: videoId)
                try? fileManager.removeItem(at: fileURL)
                downloads[videoId] = .notStarted
                return
            }

            let entity = DownloadedTrackEntity(
                id: videoId,
                title: song.title,
                artist: artist,
                duration: song.duration,
                thumbnailUrl: Self.bestStoredThumbnailUrl(song.thumbnailUrl, videoId: videoId),
                localPath: storedPath(for: fileURL),
                downloadedAt: Date(),
                itag: result.itag,
                codec: isAACStream ? "AAC" : "OPUS",
                bitrate: result.bitrate
            )
            await register(entity)

            downloads[videoId] = .completed
            lastReportedProgress.removeValue(forKey: videoId)
            let totalElapsed = CFAbsoluteTimeGetCurrent() - downloadStart
            Log.downloadManager.debug("DONE \(String(format: "%.1f", totalElapsed))s total: \(artist) - \(song.title) (itag=\(result.itag), bitrate=\(result.bitrate))")
        } catch is CancellationError {
            cancelledDownloadIds.remove(videoId)
            lastReportedProgress.removeValue(forKey: videoId)
            try? fileManager.removeItem(at: fileURL)
            downloads[videoId] = .notStarted
        } catch {
            if cancelledDownloadIds.contains(videoId) || (error as? URLError)?.code == .cancelled {
                cancelledDownloadIds.remove(videoId)
                lastReportedProgress.removeValue(forKey: videoId)
                try? fileManager.removeItem(at: fileURL)
                downloads[videoId] = .notStarted
                return
            }
            if downloads[videoId] != .completed {
                try? fileManager.removeItem(at: fileURL)
            }
            downloads[videoId] = .failed(userFacingDownloadError(error))
            lastReportedProgress.removeValue(forKey: videoId)
            Log.downloadManager.error("Failed download \(videoId): \(error.localizedDescription)")
        }
    }

    private func adoptExistingFile(at url: URL, song: SongItem) async {
        let audioMeta = await extractAudioMetadata(from: url)
        let entity = DownloadedTrackEntity(
            id: song.videoId,
            title: song.title,
            artist: song.artists.map(\.name).joined(separator: ", "),
            duration: song.duration,
            thumbnailUrl: Self.bestStoredThumbnailUrl(song.thumbnailUrl, videoId: song.videoId),
            localPath: storedPath(for: url),
            downloadedAt: (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date(),
            itag: audioMeta.itag,
            codec: audioMeta.codec,
            bitrate: audioMeta.bitrate
        )
        await register(entity)
    }

    func track(for videoId: String) -> DownloadedTrackEntity? {
        tracksById[videoId]
    }

    private func extractAudioMetadata(from fileURL: URL) async -> (itag: Int?, codec: String?, bitrate: Int?) {
        let asset = AVURLAsset(url: fileURL)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio),
              let audioTrack = tracks.first else {
            return (140, "AAC", 128_000)
        }
        let rate = try? await audioTrack.load(.estimatedDataRate)
        let bitrate = (rate.map(Int.init) ?? 0)
        let is256 = bitrate >= 240_000
        let itag = is256 ? 141 : 140
        return (itag, "AAC", bitrate > 0 ? bitrate : (is256 ? 256_000 : 128_000))
    }

    private func register(_ entity: DownloadedTrackEntity) async {
        tracksById[entity.id] = entity
        apply(tracksById)
        do {
            try await DatabaseService.shared.insertOrReplace(entity)
        } catch {
            Log.downloadManager.error("Failed to persist download \(entity.id): \(error)")
        }
    }

    // MARK: - Validation & Errors

    private func validateDownloadedFile(at url: URL) async throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        let size = values.fileSize ?? 0
        guard size >= Self.minimumAudioBytes else {
            Log.downloadManager.error("Downloaded file too small (\(size) bytes) — likely a dead stream URL")
            throw DownloadError.invalidStreamURL
        }

        let asset = AVURLAsset(url: url)
        let audioTracks: [AVAssetTrack]
        do {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            Log.downloadManager.error("Cannot open downloaded file as audio: \(error.localizedDescription)")
            throw DownloadError.invalidStreamURL
        }
        guard !audioTracks.isEmpty else {
            Log.downloadManager.error("Downloaded file has no audio track — rejecting as invalid stream")
            throw DownloadError.invalidStreamURL
        }
    }

    private func userFacingDownloadError(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "No internet connection."
            case .timedOut:
                return "The download timed out."
            default:
                break
            }
        }
        if let downloadError = error as? DownloadError {
            return downloadError.errorDescription ?? "Download failed. Try again."
        }
        let nsError = error as NSError
        if nsError.domain == AVFoundationErrorDomain {
            return "Could not process this track for offline playback. Try again."
        }
        return "Download failed. Try again."
    }

    // MARK: - State

    static func shouldRefreshPersistedLibrary(
        old: [String: DownloadState],
        new: [String: DownloadState]
    ) -> Bool {
        for (videoId, newState) in new {
            let oldState = old[videoId] ?? .notStarted
            if oldState == newState { continue }
            switch (oldState, newState) {
            case (.downloading, .completed), (.downloading, .failed),
                 (.completed, .notStarted), (.failed, .notStarted),
                 (.notStarted, .completed):
                return true
            default:
                continue
            }
        }
        for (videoId, oldState) in old where new[videoId] == nil {
            if case .completed = oldState { return true }
        }
        return false
    }

    private func cancelAllActiveDownloads() {
        downloadQueue.removeAll()
        queuedIds.removeAll()
        for (videoId, state) in downloads {
            if case .downloading = state {
                cancelledDownloadIds.insert(videoId)
            }
        }
        for (videoId, session) in activeFFmpegSessions {
            cancelledDownloadIds.insert(videoId)
            session.cancel()
        }
        activeFFmpegSessions.removeAll()
    }

    private func setProgress(_ fraction: Double, for videoId: String) {
        let clamped = min(0.99, max(0, fraction))
        let last = lastReportedProgress[videoId] ?? -1
        guard clamped >= 0.99 || last < 0 || clamped - last >= 0.02 else { return }
        lastReportedProgress[videoId] = clamped
        downloads[videoId] = .downloading(clamped)
    }

    private func prefetchArtwork(from thumbnailUrl: String?, videoId: String) async -> Data? {
        var candidates: [String] = []
        if let highRes = ArtworkURLs.highRes(thumbnailUrl) {
            candidates.append(highRes)
        }
        if let maxRes = ArtworkURLs.maxResVariant(thumbnailUrl), !candidates.contains(maxRes) {
            candidates.append(maxRes)
        }
        if let sdRes = ArtworkURLs.sdVariant(thumbnailUrl), !candidates.contains(sdRes) {
            candidates.append(sdRes)
        }
        let fallback = ArtworkURLs.fallback(for: videoId)
        if !candidates.contains(fallback) {
            candidates.append(fallback)
        }

        let urls = candidates.compactMap(URL.init(string:))
        var bestImage: UIImage?
        var bestArea: CGFloat = 0

        for url in urls {
            guard let image = try? await ArtworkLoader.image(for: url) else { continue }
            let maxSide = max(image.size.width * image.scale, image.size.height * image.scale)
            let area = (image.size.width * image.scale) * (image.size.height * image.scale)
            if maxSide >= Self.preferredMinArtworkDimension {
                return image.jpegData(compressionQuality: 0.9)
            }
            if area > bestArea {
                bestArea = area
                bestImage = image
            }
        }

        return bestImage?.jpegData(compressionQuality: 0.9)
    }

    // MARK: - File Transfer (ffmpeg)

    private func downloadToFile(
        from url: URL,
        to destination: URL,
        videoId: String,
        userAgent: String? = nil,
        clientName: String? = nil
    ) async throws {
        guard let caPath = Bundle.main.path(forResource: "cacert", ofType: "pem") else {
            throw NSError(
                domain: "DownloadManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "CA certificate bundle not found"]
            )
        }

        let resolvedUA = (userAgent?.isEmpty == false)
            ? userAgent!
            : YouTubeClient.webUserAgent

        var headerLines = ["User-Agent: \(resolvedUA)"]
        if clientName == "WEB_MUSIC" || clientName == "WEB_REMIX" {
            headerLines.append("Origin: https://music.youtube.com")
            headerLines.append("Referer: https://music.youtube.com/")
        } else if clientName == "WEB" || clientName == "TVHTML5" || clientName == "TVHTML5_SIMPLY_EMBEDDED_PLAYER" {
            headerLines.append("Origin: https://www.youtube.com")
            headerLines.append("Referer: https://www.youtube.com/")
        }
        let headersArg = headerLines.joined(separator: "\r\n") + "\r\n"

        let args = [
            "-y",
            "-rw_timeout", "30000000",
            "-cafile", caPath,
            "-headers", headersArg,
            "-i", url.absoluteString,
            "-c", "copy",
            destination.path
        ]

        try await runFFmpeg(arguments: args, videoId: videoId) { [weak self] size in
            Task { @MainActor in
                let fraction = 0.05 + 0.80 * (1 - exp(-Double(size) / 5_000_000))
                self?.setProgress(fraction, for: videoId)
            }
        }
    }

    private func runFFmpeg(
        arguments: [String],
        videoId: String? = nil,
        onSize: ((Int64) -> Void)? = nil
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let lock = NSLock()
            var finished = false
            let finish: (Result<Void, Error>) -> Void = { result in
                lock.lock()
                defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                continuation.resume(with: result)
            }

            let session = FFmpegKit.execute(
                withArgumentsAsync: arguments,
                withCompleteCallback: { [weak self] session in
                    if let videoId {
                        Task { @MainActor in
                            self?.activeFFmpegSessions.removeValue(forKey: videoId)
                        }
                    }
                    let rc = session?.getReturnCode()
                    if ReturnCode.isSuccess(rc) {
                        finish(.success(()))
                    } else if ReturnCode.isCancel(rc) {
                        finish(.failure(CancellationError()))
                    } else {
                        let output = session?.getOutput() ?? "unknown"
                        Log.downloadManager.debug("FFmpeg output: \(output)")
                        finish(.failure(NSError(
                            domain: "DownloadManager",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "FFmpeg processing failed"]
                        )))
                    }
                },
                withLogCallback: nil,
                withStatisticsCallback: { statistics in
                    guard let statistics, let onSize else { return }
                    onSize(Int64(statistics.getSize()))
                }
            )

            if let videoId, let session {
                Task { @MainActor in
                    self.activeFFmpegSessions[videoId] = session
                }
            }
        }
    }

}

// MARK: - Delete & queries

extension DownloadManager {
    func delete(videoId: String) async {
        await removeDownloads(videoIds: [videoId])
    }

    func deleteAll() async {
        guard !isMutatingLibrary else { return }
        isMutatingLibrary = true
        defer { isMutatingLibrary = false }

        cancelAllActiveDownloads()
        tracksById.removeAll()
        downloads.removeAll()
        lastReportedProgress.removeAll()
        apply([:])

        let dirURL = downloadsDir
        let fm = fileManager
        await Task.detached(priority: .utility) {
            let urls = (try? fm.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            for url in urls where url.pathExtension.lowercased() == "m4a" {
                try? fm.removeItem(at: url)
            }
        }.value

        try? await DatabaseService.shared.write { db in
            try db.execute(sql: "DELETE FROM downloaded_track")
        }
    }

    // MARK: - Local URL Resolution

    func localURL(for videoId: String) async -> URL? {
        if let track = tracksById[videoId], let url = resolvedURL(for: track) {
            repairStoredPathIfNeeded(track, url: url)
            return url
        }

        guard let entity = try? await DatabaseService.shared.fetchOne(
            DownloadedTrackEntity.self,
            key: videoId
        ) else {
            Log.downloadManager.debug("localURL: no DB entity for \(videoId)")
            return nil
        }

        guard let url = resolvedURL(for: entity) else {
            Log.downloadManager.debug("localURL: \(videoId) file not found (stored=\(entity.localPath))")
            return nil
        }

        var fixed = entity
        fixed.localPath = storedPath(for: url)
        tracksById[fixed.id] = fixed
        if fixed.localPath != entity.localPath {
            try? await DatabaseService.shared.save(fixed)
        }
        apply(tracksById)
        return url
    }

    private func repairStoredPathIfNeeded(_ track: DownloadedTrackEntity, url: URL) {
        let current = storedPath(for: url)
        guard track.localPath != current else { return }
        var fixed = track
        fixed.localPath = current
        tracksById[fixed.id] = fixed
        apply(tracksById)
        Task { try? await DatabaseService.shared.save(fixed) }
    }

    // MARK: - Query Helpers

    func isDownloaded(videoId: String) -> Bool {
        tracksById[videoId] != nil
    }

    func fetchAll() async -> [DownloadedTrackEntity] {
        Array(tracksById.values)
    }

    func fetchAllSorted() async -> [DownloadedTrackEntity] {
        tracks
    }

    private func fetchAllFromDatabase() async -> [DownloadedTrackEntity] {
        (try? await DatabaseService.shared.fetchAll(DownloadedTrackEntity.self)) ?? []
    }

    var activeDownloads: [(videoId: String, progress: Double)] {
        downloads.compactMap { videoId, state in
            if case .downloading(let progress) = state {
                return (videoId, progress)
            }
            return nil
        }
        .sorted { $0.progress > $1.progress }
    }

    func totalStorageBytes() async -> Int64 {
        var total: Int64 = 0
        for track in tracksById.values {
            guard let url = resolvedURL(for: track) else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    func state(for videoId: String) -> DownloadState {
        if let state = downloads[videoId], state != .notStarted {
            return state
        }
        return tracksById[videoId] != nil ? .completed : .notStarted
    }

    private func ffmpegMetadataArgs(title: String, artist: String) -> [String] {
        ["-metadata", "title=\(title)", "-metadata", "artist=\(artist)"]
    }

    private func writeTempArtwork(_ data: Data?) throws -> URL? {
        guard let data else { return nil }
        let url = fileManager.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        try data.write(to: url)
        return url
    }

    private func attachMetadata(
        to fileURL: URL,
        title: String,
        artist: String,
        artworkData: Data?,
        videoId: String
    ) async throws {
        let tempOutput = fileManager.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        let artworkURL = try writeTempArtwork(artworkData)
        defer {
            try? fileManager.removeItem(at: tempOutput)
            if let artworkURL {
                try? fileManager.removeItem(at: artworkURL)
            }
        }

        var args = ["-y", "-i", fileURL.path]
        if let artworkURL {
            args += [
                "-i", artworkURL.path,
                "-map", "0:a",
                "-map", "1",
                "-c:a", "copy",
                "-c:v", "mjpeg",
                "-disposition:v", "attached_pic"
            ]
        } else {
            args += ["-c", "copy"]
        }
        args += ffmpegMetadataArgs(title: title, artist: artist)
        args.append(tempOutput.path)

        try await runFFmpeg(arguments: args, videoId: videoId)
        try? fileManager.removeItem(at: fileURL)
        try fileManager.moveItem(at: tempOutput, to: fileURL)
    }

    private func processAudio(_ request: TranscodeRequest, videoId: String) async throws {
        let bitrate = Self.transcodeBitrate(for: SettingsStore.shared.downloadQuality)
        let tempOutput = fileManager.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        let artworkURL = try writeTempArtwork(request.artworkData)
        defer {
            try? fileManager.removeItem(at: tempOutput)
            if let artworkURL {
                try? fileManager.removeItem(at: artworkURL)
            }
        }

        var args = ["-y", "-i", request.inputURL.path]
        if let artworkURL {
            args += [
                "-i", artworkURL.path,
                "-map", "0:a",
                "-map", "1",
                "-c:a", "aac",
                "-b:a", "\(bitrate)",
                "-c:v", "mjpeg",
                "-disposition:v", "attached_pic"
            ]
        } else {
            args += ["-c:a", "aac", "-b:a", "\(bitrate)"]
        }
        args += ffmpegMetadataArgs(title: request.title, artist: request.artist)
        args.append(tempOutput.path)

        try await runFFmpeg(arguments: args, videoId: videoId)
        try? fileManager.removeItem(at: request.outputURL)
        try fileManager.moveItem(at: tempOutput, to: request.outputURL)
    }

    private struct TranscodeRequest {
        let inputURL: URL
        let outputURL: URL
        let title: String
        let artist: String
        let artworkData: Data?
    }
}

enum DownloadError: Error, LocalizedError {
    case invalidStreamURL
    case transcodeFailed

    var errorDescription: String? {
        switch self {
        case .invalidStreamURL:
            return "The stream URL returned by the server was invalid"
        case .transcodeFailed:
            return "Could not convert this track for offline playback."
        }
    }
}

// MARK: - Environment

private struct DownloadManagerEnvironmentKey: EnvironmentKey {
    @MainActor static var defaultValue: DownloadManager { .shared }
}

extension EnvironmentValues {
    var downloadManager: DownloadManager {
        get { self[DownloadManagerEnvironmentKey.self] }
        set { self[DownloadManagerEnvironmentKey.self] = newValue }
    }
}
