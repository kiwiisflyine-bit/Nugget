//
//  PlaybackManager.swift
//  Nugget
//
//  
//

import Foundation

/// Resolves streams and hands off to PlayerController, trying the client fallback chain.
actor PlaybackManager {
    static let shared = PlaybackManager()

    private var inflightResolutions: [String: Task<PlaybackResult, Error>] = [:]

    private func resolutionKey(videoId: String, forDownload: Bool) -> String {
        forDownload ? "\(videoId):download" : videoId
    }

    private init() {}

    /// Resolve a video and start playback. Returns the result used, or throws.
    @discardableResult
    func resolveAndPlay(videoId: String, loadToken: UUID? = nil) async throws -> PlaybackResult {
        await MainActor.run { SponsorBlockIntegration.shared.warm(for: videoId) }
        try Task.checkCancellation()

        if let localPath = await DownloadManager.shared.localURL(for: videoId) {
            if let loadToken {
                let isCurrent = await MainActor.run { NowPlaying.shared.currentLoadToken == loadToken }
                guard isCurrent else {
                    Log.playbackManager.notice("Local playback superseded for \(videoId)")
                    throw CancellationError()
                }
            }
            let song = await MainActor.run { NowPlaying.shared.queueSongs.first { $0.videoId == videoId } }
            let artists = song?.artists ?? []
            let downloadedTrack = await DownloadManager.shared.track(for: videoId)
            await PlayerController.shared.play(
                url: localPath.absoluteString,
                title: song?.title,
                artist: song?.artists.map(\.name).joined(separator: ", "),
                videoId: videoId,
                duration: song.map { TimeInterval($0.duration) },
                artists: artists,
                thumbnailUrl: song?.thumbnailUrl,
                loadToken: loadToken
            )
            await MainActor.run {
                NowPlaying.shared.updateVideoAvailability()
                if let downloadedTrack {
                    NowPlaying.shared.updateAudioQuality(
                        itag: downloadedTrack.itag,
                        codec: downloadedTrack.codec,
                        bitrate: downloadedTrack.bitrate
                    )
                }
            }
            return PlaybackResult(
                streamUrl: localPath.absoluteString,
                itag: downloadedTrack?.itag ?? 0,
                mimeType: downloadedTrack?.codec == "OPUS" ? "audio/webm; codecs=\"opus\"" : "audio/mp4",
                bitrate: downloadedTrack?.bitrate ?? 0,
                audioQuality: "local",
                videoId: videoId,
                title: song?.title,
                author: song?.artists.map(\.name).joined(separator: ", "),
                duration: song?.duration,
                expiresInSeconds: Int.max,
                clientName: "local",
                userAgent: nil,
                musicVideoType: nil,
                hasVideoContent: false,
                muxedStreamUrl: nil,
                loudnessDb: nil
            )
        }

        if let cached = await StreamCache.shared.get(videoId: videoId) {
            if let loadToken {
                let isCurrent = await MainActor.run { NowPlaying.shared.currentLoadToken == loadToken }
                guard isCurrent else {
                    Log.playbackManager.notice("Cached playback superseded for \(videoId)")
                    throw CancellationError()
                }
            }
            let queueSong = await queueSong(for: videoId)
            await PlayerController.shared.play(
                url: cached.streamUrl,
                title: cached.title,
                artist: cached.author,
                videoId: videoId,
                duration: cached.duration.flatMap { $0 > 0 ? TimeInterval($0) : nil },
                artists: queueSong?.artists ?? [],
                loudnessDb: cached.loudnessDb,
                thumbnailUrl: queueSong?.thumbnailUrl,
                userAgent: cached.userAgent,
                clientName: cached.clientName,
                loadToken: loadToken
            )
            await publishVideoAvailability(result: cached, videoId: videoId, rowType: queueSong?.musicVideoType)
            await MainActor.run {
                NowPlaying.shared.updateAudioQuality(itag: cached.itag, mimeType: cached.mimeType, bitrate: cached.bitrate)
            }
            return cached
        }

        try Task.checkCancellation()

        let result: PlaybackResult
        if let existing = inflightResolutions[videoId] {
            result = try await existing.value
        } else {
            let task = Task { [self] in
                try await resolveFromNetwork(videoId: videoId, preferredFormat: nil, forDownload: false)
            }
            inflightResolutions[videoId] = task
            defer { clearInflight(key: videoId) }
            result = try await task.value
        }

        try Task.checkCancellation()
        if let loadToken {
            let isCurrent = await MainActor.run { NowPlaying.shared.currentLoadToken == loadToken }
            guard isCurrent else {
                Log.playbackManager.notice("Network playback superseded for \(videoId)")
                throw CancellationError()
            }
        }
        await playNetworkResult(result, videoId: videoId, loadToken: loadToken)
        return result
    }

    private func playNetworkResult(_ result: PlaybackResult, videoId: String, loadToken: UUID? = nil) async {
        if let loadToken {
            let isCurrent = await MainActor.run { NowPlaying.shared.currentLoadToken == loadToken }
            guard isCurrent else {
                Log.playbackManager.notice("playNetworkResult discarded: loadToken superseded")
                return
            }
        }
        let queueSong = await queueSong(for: videoId)
        await PlayerController.shared.play(
            url: result.streamUrl,
            title: result.title,
            artist: result.author,
            videoId: videoId,
            duration: result.duration.flatMap { $0 > 0 ? TimeInterval($0) : nil },
            artists: queueSong?.artists ?? [],
            loudnessDb: result.loudnessDb,
            thumbnailUrl: queueSong?.thumbnailUrl,
            userAgent: result.userAgent,
            clientName: result.clientName,
            loadToken: loadToken
        )
        await publishVideoAvailability(result: result, videoId: videoId, rowType: queueSong?.musicVideoType)
        await MainActor.run {
            NowPlaying.shared.updateAudioQuality(itag: result.itag, mimeType: result.mimeType, bitrate: result.bitrate)
        }
    }

    private func clearInflight(key: String) {
        inflightResolutions.removeValue(forKey: key)
    }

    private func queueSong(for videoId: String) async -> SongItem? {
        await MainActor.run {
            NowPlaying.shared.queueSongs.first { $0.videoId == videoId }
        }
    }

    private func publishVideoAvailability(result: PlaybackResult, videoId: String, rowType: String?) async {
        let type = result.musicVideoType ?? rowType
        let hasVideo = await VideoAvailability.shared.hasVideo(
            videoId: videoId, rowType: rowType, result: result, using: InnerTubeClient.nuggetShared
        )
        await MainActor.run {
            NowPlaying.shared.updateVideoAvailability(musicVideoType: type, hasVideo: hasVideo)
        }
    }

    private func resolveVideoOutcome(videoId: String, using client: InnerTubeClient) async throws -> VideoStream {
        var request = StreamResolveRequest(videoId: videoId)
        request.options.audioQuality = SettingsStore.shared.audioQuality
        await InnerTubeClient.updateStreamAuth()

        if request.options.audioQuality == .aac256 {
            request.chain = ClientFallbackChain.aac256Chain
            do {
                return try await StreamFallback.resolveVideo(
                    request,
                    using: client,
                    providers: .nuggetLive
                )
            } catch {
                request.chain = ClientFallbackChain.preferred
                return try await StreamFallback.resolveVideo(
                    request,
                    using: client,
                    providers: .nuggetLive
                )
            }
        } else {
            request.chain = ClientFallbackChain.preferred
            return try await StreamFallback.resolveVideo(
                request,
                using: client,
                providers: .nuggetLive
            )
        }
    }

    func resolveVideoStream(videoId: String) async throws -> String {
        let resolved = try await resolveVideoOutcome(videoId: videoId, using: InnerTubeClient.streamShared)

        switch resolved {
        case .muxed(let url):
            return url
        case .split(let videoURL, let audioURL, let duration):
            return StreamFallback.combineVideoAndAudio(
                videoURL: videoURL,
                audioURL: audioURL,
                duration: duration
            )
        case .hls(let url):
            return url
        }
    }

    func resolveMuxedURL(videoId: String) async throws -> String {
        if let cached = await StreamCache.shared.get(videoId: videoId),
           let muxed = cached.muxedStreamUrl {
            return muxed
        }
        return try await resolveVideoStream(videoId: videoId)
    }

    func resolveVideoOnlyURL(videoId: String) async throws -> String {
        let resolved = try await resolveVideoOutcome(videoId: videoId, using: InnerTubeClient.nuggetShared)

        switch resolved {
        case .muxed(let url):
            return url
        case .split(let videoURL, _, _):
            return videoURL
        case .hls(let url):
            return url
        }
    }

    /// Stable per-launch session id for PoToken minting.
    static let sessionId: String = UUID().uuidString

    func resolve(videoId: String, preferredFormat: Format? = nil, forDownload: Bool = false) async throws -> PlaybackResult {
        if !forDownload, let cached = await StreamCache.shared.get(videoId: videoId) {
            return cached
        }

        let key = resolutionKey(videoId: videoId, forDownload: forDownload)
        if let existing = inflightResolutions[key] {
            return try await existing.value
        }

        let task = Task { [self] in
            try await resolveFromNetwork(videoId: videoId, preferredFormat: preferredFormat, forDownload: forDownload)
        }
        inflightResolutions[key] = task
        defer { clearInflight(key: key) }
        return try await task.value
    }

    private func resolveFromNetwork(videoId: String, preferredFormat: Format?, forDownload: Bool) async throws -> PlaybackResult {
        var request = forDownload ? StreamResolveRequest.download(videoId: videoId) : .playback(videoId: videoId)
        request.options.preferredFormat = preferredFormat
        request.options.audioQuality = SettingsStore.shared.audioQuality
        request.options.downloadQuality = SettingsStore.shared.downloadQuality
        await InnerTubeClient.updateStreamAuth()

        let wants256AAC = (forDownload && request.options.downloadQuality == .aac256)
            || (!forDownload && request.options.audioQuality == .aac256)

        if wants256AAC {
            request.chain = ClientFallbackChain.aac256Chain
            do {
                return try await StreamFallback.resolveFirstValid(
                    request,
                    using: InnerTubeClient.streamShared,
                    providers: .nuggetLive
                )
            } catch {
                Log.playbackManager.notice("256AAC chain had no stream for \(videoId); falling back to standard chain")
                request.chain = forDownload ? ClientFallbackChain.forDownload : ClientFallbackChain.preferred
                return try await StreamFallback.resolveFirstValid(
                    request,
                    using: InnerTubeClient.streamShared,
                    providers: .nuggetLive
                )
            }
        } else {
            request.chain = forDownload ? ClientFallbackChain.forDownload : ClientFallbackChain.preferred
            return try await StreamFallback.resolveFirstValid(
                request,
                using: InnerTubeClient.streamShared,
                providers: .nuggetLive
            )
        }
    }
}
