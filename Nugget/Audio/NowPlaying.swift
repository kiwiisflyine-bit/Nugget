//
//  NowPlaying.swift
//  Nugget
//
//  
//

import AVFoundation
import Foundation
import Observation
import Nuke
import SwiftUI

@Observable
@MainActor
final class NowPlaying {
    static let shared = NowPlaying()

    var title = ""
    var artist = ""
    var albumTitle = ""
    var videoId: String?
    var artists: [YTArtist] = []
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var progress: Float {
        duration > 0 ? Float(currentTime / duration) : 0
    }
    var thumbnailImage: Image?
    var thumbnailUIImage: UIImage?
    var thumbnailVersion = 0
    var dominantColors: [Color] = [Color(red: 0.15, green: 0.15, blue: 0.2), Color(red: 0.05, green: 0.05, blue: 0.08)]

    var accentColor: Color? {
        guard videoId != nil, let primary = dominantColors.first else { return nil }
        return primary
    }

    var queueSongs: [SongItem] = []
    var queueIndex = 0

    var isShuffleOn = false
    var isRepeatOn = false

    var hasVideo: Bool = false
    var isVideoMode: Bool = false
    var isVideoReady: Bool = false
    var musicVideoType: String?

    private var originalQueue: [SongItem]?

    /// Single source of truth for the active song: matches `videoId` first so
    /// the mini player, full player actions, and download button never diverge
    /// from what is actually playing.
    var currentSong: SongItem? {
        if let videoId, let match = queueSongs.first(where: { $0.videoId == videoId }) {
            return match
        }
        guard queueSongs.indices.contains(queueIndex) else { return nil }
        return queueSongs[queueIndex]
    }

    var hasNext: Bool {
        queueIndex + 1 < queueSongs.count
    }

    var hasPrevious: Bool {
        queueIndex > 0
    }

    var isBarPresented: Bool {
        videoId != nil
    }

    private var timer: Timer?
    var lastManualSkipTime: Date?
    private var isResolvingNext = false
    private var currentLoadTask: Task<Void, Never>?
    private(set) var currentLoadToken = UUID()

    var audioBadge: String?
    var is256AAC: Bool = false

    /// Recent mid-play failure timestamps per videoId, to cap retry loops.
    private var recentFailures: [String: [Date]] = [:]
    private static let maxRecoveryAttempts = 2
    private static let recoveryWindowSeconds: TimeInterval = 60

    private nonisolated static let maxArtworkPixelDimension: CGFloat = 1200
    private nonisolated static let preferredMinArtworkDimension: CGFloat = 300

    private static let queueKey = "nowPlaying.queue"
    private static let queueIndexKey = "nowPlaying.queueIndex"
    private static let shuffleKey = "nowPlaying.shuffle"
    private static let repeatKey = "nowPlaying.repeat"

    private init() {
        restoreQueueIfNeeded()
    }

    deinit {
        MainActor.assumeIsolated {
            timer?.invalidate()
            timer = nil
        }
    }

    // MARK: - Persistent queue

    private func restoreQueueIfNeeded() {
        guard SettingsStore.shared.persistQueue,
              let data = UserDefaults.standard.data(forKey: Self.queueKey),
              let songs = try? JSONDecoder().decode([SongItem].self, from: data),
              !songs.isEmpty else { return }
        queueSongs = songs
        let storedIndex: Int
        if UserDefaults.standard.object(forKey: Self.queueIndexKey) != nil {
            storedIndex = UserDefaults.standard.integer(forKey: Self.queueIndexKey)
        } else {
            storedIndex = 0
        }
        queueIndex = min(max(storedIndex, 0), songs.count - 1)
        isShuffleOn = UserDefaults.standard.bool(forKey: Self.shuffleKey)
        isRepeatOn = UserDefaults.standard.bool(forKey: Self.repeatKey)
        queueIndex = max(0, queueIndex)
    }

    func persistQueueState() {
        guard SettingsStore.shared.persistQueue else { return }
        if queueSongs.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.queueKey)
            UserDefaults.standard.removeObject(forKey: Self.queueIndexKey)
            UserDefaults.standard.removeObject(forKey: Self.shuffleKey)
            UserDefaults.standard.removeObject(forKey: Self.repeatKey)
            return
        }
        if let data = try? JSONEncoder().encode(queueSongs) {
            UserDefaults.standard.set(data, forKey: Self.queueKey)
        }
        UserDefaults.standard.set(queueIndex, forKey: Self.queueIndexKey)
        UserDefaults.standard.set(isShuffleOn, forKey: Self.shuffleKey)
        UserDefaults.standard.set(isRepeatOn, forKey: Self.repeatKey)
    }

    func setQueue(_ songs: [SongItem], startIndex: Int) {
        queueSongs = songs
        queueIndex = min(max(startIndex, 0), max(songs.count - 1, 0))
        originalQueue = nil
        isShuffleOn = false
        persistQueueState()
    }

    func repairQueueIndex() {
        if queueSongs.isEmpty {
            queueIndex = 0
            return
        }
        if let videoId, let idx = queueSongs.firstIndex(where: { $0.videoId == videoId }) {
            queueIndex = idx
        } else {
            queueIndex = min(max(queueIndex, 0), queueSongs.count - 1)
        }
    }

    func upcomingSongs(prefixLimit: Int? = nil) -> [SongItem] {
        let next = queueIndex + 1
        guard queueSongs.indices.contains(next) else { return [] }
        let rest = Array(queueSongs[next...])
        guard let prefixLimit else { return rest }
        return Array(rest.prefix(prefixLimit))
    }

    func shuffleQueue() {
        guard queueSongs.count > 1 else {
            isShuffleOn = true
            return
        }
        if originalQueue == nil {
            originalQueue = queueSongs
        }
        let prefix = queueIndex > 0 ? Array(queueSongs[0..<queueIndex]) : []
        let current = queueSongs[queueIndex]
        var rest = queueIndex + 1 < queueSongs.count ? Array(queueSongs[(queueIndex + 1)...]) : []
        rest.shuffle()
        queueSongs = prefix + [current] + rest
        queueIndex = prefix.count
        isShuffleOn = true
        persistQueueState()
    }

    func disableShuffle() {
        guard queueSongs.indices.contains(queueIndex) else { return }
        if let orig = originalQueue {
            let currentVideoId = currentSong?.videoId ?? queueSongs[queueIndex].videoId
            queueSongs = orig
            let restored = orig.firstIndex(where: { $0.videoId == currentVideoId }) ?? queueIndex
            queueIndex = min(restored, max(orig.count - 1, 0))
        }
        originalQueue = nil
        isShuffleOn = false
        persistQueueState()
    }

    func moveQueueSongs(from source: IndexSet, to destination: Int) {
        guard !source.isEmpty, queueSongs.indices.contains(source.first ?? -1) else { return }
        queueSongs.move(fromOffsets: source, toOffset: destination)
        repairQueueIndex()
        persistQueueState()
    }

    func repeatCurrent() {
        repairQueueIndex()
        guard queueSongs.indices.contains(queueIndex) else { return }
        playCurrentSong(logContext: "repeatCurrent") { [weak self] in
            self?.isRepeatOn = false
        }
    }

    func playNext(automatic: Bool = false) {
        repairQueueIndex()
        guard hasNext else { return }
        if !automatic { lastManualSkipTime = Date() }
        queueIndex += 1
        playCurrentSong(logContext: "playNext")
    }

    func playPrevious() {
        repairQueueIndex()
        guard hasPrevious else { return }
        lastManualSkipTime = Date()
        queueIndex -= 1
        playCurrentSong(logContext: "playPrevious")
    }

    func playCurrentSong(
        logContext: String,
        manageResolvingFlag: Bool = true,
        afterResolve: (() -> Void)? = nil
    ) {
        guard queueSongs.indices.contains(queueIndex) else { return }
        currentLoadTask?.cancel()

        let token = UUID()
        currentLoadToken = token

        if manageResolvingFlag {
            isResolvingNext = true
        }
        let song = queueSongs[queueIndex]
        update(with: song)
        persistQueueState()

        currentLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            Log.nowPlaying.info("[\(logContext)] Starting playback load for '\(song.title)' (\(song.videoId)), token=\(token)")
            do {
                try await PlaybackManager.shared.resolveAndPlay(videoId: song.videoId, loadToken: token)
                guard self.currentLoadToken == token else {
                    Log.nowPlaying.notice("[\(logContext)] Load completed for \(song.videoId) but superseded by newer token \(self.currentLoadToken). Discarding.")
                    return
                }
            } catch {
                if Task.isCancelled {
                    Log.nowPlaying.info("[\(logContext)] Load task cancelled for \(song.videoId)")
                    return
                }
                guard self.currentLoadToken == token else {
                    Log.nowPlaying.notice("[\(logContext)] Error caught for superseded token \(token). Ignoring.")
                    return
                }
                Log.nowPlaying.error("[\(logContext)] Failed to resolve or play \(song.title) (\(song.videoId)): \(error.localizedDescription)")
                PlayerController.shared.stop()
                if self.videoId == song.videoId {
                    self.isPlaying = false
                    self.currentTime = 0
                }
            }
            if manageResolvingFlag && self.currentLoadToken == token {
                self.isResolvingNext = false
            }
            afterResolve?()
        }
    }

    func update(title: String, artist: String?, videoId: String, album: String? = nil, artists: [YTArtist] = [], thumbnailUrl: String? = nil, audioBadge: String? = nil, is256AAC: Bool = false) {
        self.isPlaying = true
        self.title = title
        self.artists = artists
        self.artist = cleanArtistDisplay(artist ?? "")
        self.albumTitle = album ?? ""
        self.currentTime = 0
        self.duration = 0
        self.videoId = videoId
        self.hasVideo = false
        self.isVideoMode = false
        self.isVideoReady = false
        self.audioBadge = audioBadge
        self.is256AAC = is256AAC
        if let idx = queueSongs.firstIndex(where: { $0.videoId == videoId }) {
            self.queueIndex = idx
        }
        startTimer()
        loadThumbnail(videoId: videoId, thumbnailUrl: thumbnailUrl)
        preloadNextTrack()
        CanvasPrefetch.request(videoId: videoId, title: title, artist: self.artist, album: album)
    }

    func update(with song: SongItem) {
        update(
            title: song.title,
            artist: song.artists.map(\.name).joined(separator: ", "),
            videoId: song.videoId,
            album: song.album,
            artists: song.artists,
            thumbnailUrl: song.thumbnailUrl,
            audioBadge: song.audioBadge,
            is256AAC: song.is256AAC ?? false
        )
    }

    func updateAudioQuality(badge: String?, is256AAC: Bool) {
        self.audioBadge = badge
        self.is256AAC = is256AAC
    }

    func updateAudioQuality(itag: Int?, mimeType: String? = nil, codec: String? = nil, bitrate: Int? = nil) {
        self.audioBadge = AudioQualityBadgeHelper.badgeText(itag: itag, mimeType: mimeType, codec: codec, bitrate: bitrate)
        self.is256AAC = AudioQualityBadgeHelper.is256AAC(itag: itag, mimeType: mimeType, codec: codec, bitrate: bitrate)
    }

    func updateVideoAvailability(musicVideoType: String? = nil, hasVideo: Bool = false) {
        if let musicVideoType {
            self.musicVideoType = musicVideoType
        }
        self.hasVideo = hasVideo
        if hasVideo {
            PlayerController.shared.preloadVideoURL()
        }
    }

    func preloadNeighborArtwork() {
        var urls = upcomingSongs(prefixLimit: 3)
            .compactMap(\.thumbnailUrl)
            .compactMap { URL(string: ArtworkURLs.highRes($0) ?? $0) }
        let neighborIds = queueSongs.indices.compactMap { index -> String? in
            guard index == queueIndex - 1 || (index > queueIndex && index <= queueIndex + 3) else { return nil }
            return queueSongs[index].videoId
        }
        urls.append(contentsOf: neighborIds.compactMap { URL(string: Self.artworkURL(for: $0)) })
        guard !urls.isEmpty else { return }
        Task { await ImagePreloader.shared.append(urls) }
    }

    var displayArtist: String {
        let fromArray = artistDisplayString(from: artists)
        if !fromArray.isEmpty { return fromArray }
        return artist
    }

    func stopped(videoId: String?, isEof: Bool = true) {
        guard self.videoId == videoId else { return }
        if let skipTime = lastManualSkipTime, Date().timeIntervalSince(skipTime) < 2, isResolvingNext {
            return
        }
        guard isEof else {
            recoverFromPlaybackFailure(videoId: videoId)
            return
        }
        currentTime = duration
        if let finishedId = videoId,
           duration >= 600 || musicVideoType == "MUSIC_VIDEO_TYPE_PODCAST_EPISODE" {
            Task { await EpisodePlaybackStore.shared.markPlayed(videoId: finishedId) }
        }
        if isRepeatOn {
            repeatCurrent()
            return
        }
        if hasNext {
            playNext(automatic: true)
        } else if SettingsStore.shared.autoplaySimilar, let endedVideoId = videoId {
            autoplaySimilar(from: endedVideoId)
        } else {
            isPlaying = false
            stopTimer()
            PlayerController.shared.updateNowPlayingProgress()
            Task { await PlaybackStateService.shared.stopTracking() }
        }
    }

    private func autoplaySimilar(from videoId: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let radio = try await PersonalizationService.shared.fetchRadio(videoId: videoId)
                let songs = radio.songs
                guard !songs.isEmpty else {
                    self.isPlaying = false
                    return
                }
                self.queueSongs = songs
                self.queueIndex = 0
                self.isShuffleOn = false
                let first = songs[0]
                self.update(with: first)
                try await PlaybackManager.shared.resolveAndPlay(videoId: first.videoId)
                self.persistQueueState()
            } catch {
                Log.nowPlaying.error("Autoplay similar failed: \(error)")
                PlayerController.shared.stop()
                self.isPlaying = false
                self.currentTime = 0
            }
        }
    }

    private func recoverFromPlaybackFailure(videoId: String?) {
        guard let videoId else {
            isPlaying = false
            currentTime = 0
            return
        }
        PlayerController.shared.handleVideoStreamFailure()

        let livePos = PlayerController.shared.currentTime
        let progressed = max(currentTime, livePos) > 0.5

        let now = Date()
        let activeWindow = (recentFailures[videoId] ?? []).filter {
            now.timeIntervalSince($0) < Self.recoveryWindowSeconds
        }
        if !progressed || activeWindow.count >= Self.maxRecoveryAttempts {
            recentFailures[videoId] = activeWindow + [now]
            Log.nowPlaying.notice(
                "Stream failed for \(videoId) (progressed=\(progressed), attempts=\(activeWindow.count)); stopping recovery loop"
            )
            PlayerController.shared.stop()
            if self.videoId == videoId {
                isPlaying = false
                currentTime = 0
            }
            return
        }

        recentFailures[videoId] = activeWindow + [now]
        isPlaying = false
        currentTime = 0
        Log.nowPlaying.notice("Stream failed mid-play, re-resolving \(videoId)")
        Task { @MainActor [weak self] in
            await PlayerConfigStore.shared.notifyStreamRejection()
            await StreamCache.shared.remove(videoId: videoId)
            do {
                try await PlaybackManager.shared.resolveAndPlay(videoId: videoId)
                self?.recentFailures.removeValue(forKey: videoId)
            } catch {
                Log.nowPlaying.error("Mid-play recovery failed: \(error)")
                PlayerController.shared.stop()
                if let owner = self, owner.videoId == videoId {
                    owner.isPlaying = false
                    owner.currentTime = 0
                }
            }
        }
    }

    static func artworkURL(for videoId: String) -> String {
        ArtworkURLs.fallback(for: videoId)
    }

    private var lastLoadedVideoId: String?

    private func loadThumbnail(videoId: String, thumbnailUrl: String? = nil) {
        guard videoId != lastLoadedVideoId else { return }
        lastLoadedVideoId = videoId
        var thumb = thumbnailUrl
        if thumb == nil {
            thumb = queueSongs.first { $0.videoId == videoId }?.thumbnailUrl
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            if let localURL = await DownloadManager.shared.localURL(for: videoId) {
                self.loadArtworkFromLocalFile(localURL, videoId: videoId)
                return
            }
            self.loadThumbnailFromCDN(videoId: videoId, thumbnailUrl: thumb)
        }
    }

    private func loadArtworkFromLocalFile(_ fileURL: URL, videoId: String) {
        Task {
            let asset = AVURLAsset(url: fileURL)
            let metadata = try? await asset.load(.metadata)
            var artworkImage: UIImage?
            if let metadata {
                for item in metadata {
                    if let data = try? await item.load(.dataValue),
                       let image = UIImage(data: data) {
                        artworkImage = image
                        break
                    }
                }
            }

            await MainActor.run { [weak self] in
                guard let self, self.lastLoadedVideoId == videoId else { return }
                if let artworkImage {
                    self.publishArtwork(artworkImage)
                } else {
                    self.loadThumbnailFromCDN(videoId: videoId)
                }
            }
        }
    }

    /// Prepares artwork off the main actor: caps huge dimensions to avoid lag
    /// while preserving the image's natural aspect ratio.
    nonisolated private static func prepareArtwork(_ image: UIImage) -> UIImage {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let maxSide = max(pixelWidth, pixelHeight)

        guard maxSide > maxArtworkPixelDimension, maxSide > 0 else {
            return image
        }

        let scaleFactor = maxArtworkPixelDimension / maxSide
        let targetSize = CGSize(
            width: max(1, (image.size.width * scaleFactor).rounded()),
            height: max(1, (image.size.height * scaleFactor).rounded())
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    nonisolated private static func isSharpEnough(_ image: UIImage) -> Bool {
        let minSide = min(image.size.width * image.scale, image.size.height * image.scale)
        return minSide >= preferredMinArtworkDimension
    }

    /// Publishes a loaded image as the current artwork, preserving aspect ratio.
    private func publishArtwork(_ image: UIImage) {
        let targetVideoId = self.videoId
        Task.detached(priority: .userInitiated) { [weak self] in
            let prepared = Self.prepareArtwork(image)
            let colors = prepared.extractDominantColors()
            await MainActor.run {
                guard let owner = self, owner.videoId == targetVideoId else { return }
                owner.thumbnailUIImage = prepared
                owner.thumbnailImage = Image(uiImage: prepared)
                owner.thumbnailVersion &+= 1
                owner.dominantColors = colors
                PlayerController.shared.updateNowPlayingArtwork()
            }
        }
    }

    private func loadThumbnailFromCDN(videoId: String, thumbnailUrl: String? = nil) {
        var candidates: [String] = []
        if let upgraded = ArtworkURLs.highRes(thumbnailUrl) {
            if let maxRes = ArtworkURLs.maxResVariant(upgraded) {
                candidates.append(maxRes)
            }
            if let standard = ArtworkURLs.sdVariant(upgraded) {
                candidates.append(standard)
            }
            candidates.append(upgraded)
        }
        let fallback = Self.artworkURL(for: videoId)
        if !candidates.contains(fallback) {
            candidates.append(fallback)
        }
        let urls = candidates.compactMap(URL.init(string:))
        guard !urls.isEmpty else {
            thumbnailUIImage = nil
            thumbnailImage = Image(systemName: "music.note")
            thumbnailVersion &+= 1
            updateDominantColors(from: nil)
            return
        }

        var paintedIndex: Int?
        for (index, url) in urls.enumerated() {
            if let cached = ArtworkLoader.cachedImage(for: url), Self.isSharpEnough(cached) {
                publishArtwork(cached)
                paintedIndex = index
                break
            }
        }

        let fetchCount = paintedIndex ?? urls.count
        if fetchCount == 0 {
            return
        }
        if paintedIndex == nil {
            thumbnailImage = nil
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            var fallbackTinyImage: UIImage?
            for url in urls.prefix(fetchCount) {
                guard self.lastLoadedVideoId == videoId else { return }
                do {
                    let platformImage = try await ArtworkLoader.image(for: url)
                    if Self.isSharpEnough(platformImage) {
                        guard self.lastLoadedVideoId == videoId else { return }
                        self.publishArtwork(platformImage)
                        return
                    } else if fallbackTinyImage == nil {
                        fallbackTinyImage = platformImage
                    }
                } catch {
                    continue
                }
            }

            if let fallbackTinyImage {
                guard self.lastLoadedVideoId == videoId else { return }
                self.publishArtwork(fallbackTinyImage)
                return
            }

            if paintedIndex == nil {
                guard self.lastLoadedVideoId == videoId else { return }
                self.thumbnailImage = Image(systemName: "music.note")
                self.thumbnailVersion &+= 1
                self.updateDominantColors(from: nil)
            }
        }
    }

    private func preloadNextTrack() {
        guard hasNext else { return }
        let nextId = queueSongs[queueIndex + 1].videoId
        SponsorBlockIntegration.shared.warm(for: nextId)
        loggedTask(Log.nowPlaying, "Pre-resolve failed") {
            _ = try await PlaybackManager.shared.resolve(videoId: nextId)
            Log.nowPlaying.debug("Pre-resolved next track: \(nextId)")
        }
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.timerTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @MainActor
    private func timerTick() {
        currentTime = PlayerController.shared.currentTime
        duration = PlayerController.shared.duration
        PlayerController.shared.updateNowPlayingProgress()
        SponsorBlockIntegration.shared.tick()
        if let videoId, duration >= 600 || musicVideoType == "MUSIC_VIDEO_TYPE_PODCAST_EPISODE" {
            let vid = videoId
            let pos = currentTime
            let dur = duration
            Task {
                await EpisodePlaybackStore.shared.savePosition(videoId: vid, position: pos, duration: dur)
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    @MainActor
    private func updateDominantColors(from uiImage: UIImage?) {
        guard let uiImage = uiImage else {
            self.dominantColors = [Color(red: 0.15, green: 0.15, blue: 0.2), Color(red: 0.05, green: 0.05, blue: 0.08)]
            return
        }
        self.dominantColors = uiImage.extractDominantColors()
    }
}

// MARK: - Module-level artist name cleaner

func artistDisplayString(from artists: [YTArtist]) -> String {
    artists
        .map { cleanArtistDisplay($0.name) }
        .filter { !$0.isEmpty }
        .joined(separator: ", ")
}

func cleanArtistDisplay(_ name: String) -> String {
    var tempName = name

    for suffix in [" - Topic", " - topic", " - TOPIC"] where tempName.lowercased().hasSuffix(suffix.lowercased()) {
        tempName = String(tempName.dropLast(suffix.count))
    }

    if let r = try? NSRegularExpression(pattern: "\\s*[\\(\\[]\\d{4}[\\)\\]]\\s*$") {
        tempName = r.stringByReplacingMatches(
            in: tempName,
            range: NSRange(tempName.startIndex..., in: tempName),
            withTemplate: ""
        )
    }

    let separatorSet = CharacterSet(charactersIn: ",&•·|")
    let parts = tempName
        .components(separatedBy: separatorSet)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    let cleanParts = parts.filter { !_isJunkArtistSegment($0) }
    if cleanParts.isEmpty {
        return ""
    }
    return cleanParts.joined(separator: ", ")
}

private func _isJunkArtistSegment(_ segment: String) -> Bool {
    let lower = segment.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if lower.isEmpty || lower == "•" || lower == "·" { return true }

    let junkLabels: Set<String> = [
        "song", "video", "track", "music", "podcast", "episode",
        "album", "playlist", "released", "year", "plays", "views",
        "downloads", "listeners", "subscribers", "watchers", "likes"
    ]
    if junkLabels.contains(lower) { return true }

    let patterns = [
        "^[\\d,\\.]+[KMBT]?\\s*(views|downloads|listeners|subscribers|plays|watchers|likes?)?$",
        "^\\d{4}$",
        "^[\\d,\\.\\s]+[KMBT]?$"
    ]
    for pattern in patterns where lower.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
        return true
    }
    return false
}
