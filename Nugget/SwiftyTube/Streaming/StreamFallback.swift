//
//  StreamFallback.swift
//  SwiftyTube
//
//  Created on 03/10/2026.
//

import Foundation

/// Loop behavior for `StreamFallback.resolveFirstValid`.
public struct FallbackPolicy: Sendable {
    /// Return a fresh cache entry, no network.
    public var useCache: Bool
    /// Store hits in the cache.
    public var storeInCache: Bool
    /// Validate URLs (honor `skipValidation`).
    public var validateStreams: Bool
    /// Expired-cache fallback on total failure.
    public var expiredCacheFallback: Bool
    /// Prefer AAC, keep first non-AAC aside.
    public var preferAAC: Bool

    public init(
        useCache: Bool,
        storeInCache: Bool,
        validateStreams: Bool,
        expiredCacheFallback: Bool,
        preferAAC: Bool
    ) {
        self.useCache = useCache
        self.storeInCache = storeInCache
        self.validateStreams = validateStreams
        self.expiredCacheFallback = expiredCacheFallback
        self.preferAAC = preferAAC
    }

    /// Playback: cache, validate, expired-cache fallback.
    public static let playback = FallbackPolicy(
        useCache: true,
        storeInCache: true,
        validateStreams: true,
        expiredCacheFallback: true,
        preferAAC: false
    )

    /// Download: no cache, validate, AAC preferred with non-AAC fallback.
    public static let download = FallbackPolicy(
        useCache: false,
        storeInCache: false,
        validateStreams: true,
        expiredCacheFallback: false,
        preferAAC: true
    )
}

/// What to resolve, in what order, how to behave.
public struct StreamResolveRequest: Sendable {
    public var videoId: String
    public var chain: [FallbackClient]
    public var options: StreamResolveOptions
    public var policy: FallbackPolicy

    public init(
        videoId: String,
        chain: [FallbackClient] = ClientFallbackChain.preferred,
        options: StreamResolveOptions = .default,
        policy: FallbackPolicy = .playback
    ) {
        self.videoId = videoId
        self.chain = chain
        self.options = options
        self.policy = policy
    }

    /// Playback request for a video.
    public static func playback(
        videoId: String,
        options: StreamResolveOptions = .default
    ) -> StreamResolveRequest {
        let chain = (options.audioQuality == .aac256)
            ? ClientFallbackChain.aac256Chain
            : ClientFallbackChain.preferred
        return StreamResolveRequest(videoId: videoId, chain: chain, options: options, policy: .playback)
    }

    /// Download request for a video.
    public static func download(
        videoId: String,
        options: StreamResolveOptions = .default
    ) -> StreamResolveRequest {
        var options = options
        options.forDownload = true
        let chain = (options.downloadQuality == .aac256 || options.audioQuality == .aac256)
            ? ClientFallbackChain.aac256Chain
            : ClientFallbackChain.forDownload
        return StreamResolveRequest(
            videoId: videoId,
            chain: chain,
            options: options,
            policy: .download
        )
    }
}

/// Muxed URL or video+audio pair.
public enum VideoStream: Sendable {
    case muxed(String)
    case split(video: String, audio: String, duration: Int?)
    case hls(String)
}

/// Shared fallback loops (player wiring stays in apps).
public enum StreamFallback: Sendable {
    /// First valid stream across the chain. PoTokens minted lazily.
    public static func resolveFirstValid(
        _ request: StreamResolveRequest,
        using innerTube: InnerTubeClient,
        cache: StreamCache = .shared,
        providers: StreamResolveProviders = .none
    ) async throws -> PlaybackResult {
        if request.policy.useCache, let cached = await cache.get(videoId: request.videoId) {
            return cached
        }

        var poTokenTask: Task<PoTokenResult?, Never>?
        if providers.poTokenProvider != nil,
           request.chain.contains(where: { $0.client.useWebPoTokens }) {
            let videoId = request.videoId
            poTokenTask = Task { await providers.poTokenProvider?(videoId) }
        }
        defer { poTokenTask?.cancel() }

        func poTokenOptions() async -> (poToken: String?, streamingDataPoToken: String?) {
            guard let poTokenTask else { return (nil, nil) }
            let resolved = await poTokenTask.value
            return (resolved?.playerRequestPoToken, resolved?.streamingDataPoToken)
        }

        var lastError: Error?
        var nonAACFallback: PlaybackResult?

        for entry in request.chain {
            var options = request.options
            if entry.client.useWebPoTokens, poTokenTask != nil {
                let minted = await poTokenOptions()
                options.poToken = minted.poToken ?? options.poToken
                options.streamingDataPoToken = minted.streamingDataPoToken
                    ?? options.streamingDataPoToken
            }

            do {
                let result = try await StreamResolver.resolve(
                    videoId: request.videoId,
                    client: entry.client,
                    using: innerTube,
                    options: options,
                    providers: providers
                )

                if request.policy.validateStreams, !entry.skipValidation {
                    let valid = await StreamResolver.validateStream(
                        url: result.streamUrl,
                        onStreamRejection: providers.onStreamRejection
                    )
                    guard valid else {
                        lastError = StreamError.validationFailed(result.clientName)
                        SwiftyTubeLog.debug("\(result.clientName) Range validation failed, trying next")
                        continue
                    }
                }

                if request.policy.preferAAC {
                    let mime = result.mimeType.lowercased()
                    let isAAC = result.itag == 141
                        || mime.contains("mp4a")
                        || mime.contains("aac")
                        || mime.contains("audio/mp4")
                    if !isAAC {
                        SwiftyTubeLog.debug("\(result.clientName) returned non-AAC (\(result.mimeType))")
                        if nonAACFallback == nil {
                            nonAACFallback = result
                        }
                        continue
                    }
                } else if request.policy.storeInCache {
                    await cache.set(videoId: request.videoId, result: result)
                }
                return result
            } catch {
                lastError = error
                SwiftyTubeLog.error("\(entry.client.clientName) failed: \(error.localizedDescription)")
            }
        }

        if request.policy.preferAAC, let fallback = nonAACFallback {
            SwiftyTubeLog.debug("No AAC stream found - falling back to \(fallback.mimeType)")
            return fallback
        }

        if request.policy.expiredCacheFallback,
           let expired = await cache.getExpired(videoId: request.videoId) {
            SwiftyTubeLog.notice("All clients failed for \(request.videoId), falling back to expired cache")
            return expired
        }
        throw lastError ?? StreamError.allClientsFailed
    }

    /// Muxed URL or split pair. Throws `noSuitableFormat`.
    public static func resolveVideo(
        _ request: StreamResolveRequest,
        using innerTube: InnerTubeClient,
        providers: StreamResolveProviders = .none
    ) async throws -> VideoStream {
        var poTokenTask: Task<PoTokenResult?, Never>?
        if providers.poTokenProvider != nil,
           request.chain.contains(where: { $0.client.useWebPoTokens }) {
            let videoId = request.videoId
            poTokenTask = Task { await providers.poTokenProvider?(videoId) }
        }
        defer { poTokenTask?.cancel() }

        func poTokenOptions() async -> (poToken: String?, streamingDataPoToken: String?) {
            guard let poTokenTask else { return (nil, nil) }
            let resolved = await poTokenTask.value
            return (resolved?.playerRequestPoToken, resolved?.streamingDataPoToken)
        }

        var lastError: Error?

        for entry in request.chain {
            do {
                let signatureTimestamp: Int?
                if entry.client.useSignatureTimestamp {
                    signatureTimestamp = await providers.signatureTimestamp?()
                } else {
                    signatureTimestamp = nil
                }

                var poToken = request.options.poToken
                var streamingDataPoToken = request.options.streamingDataPoToken
                if entry.client.useWebPoTokens, poTokenTask != nil {
                    let minted = await poTokenOptions()
                    poToken = minted.poToken ?? poToken
                    streamingDataPoToken = minted.streamingDataPoToken ?? streamingDataPoToken
                }

                let response: PlayerResponse = try await innerTube.playerResponse(
                    videoId: request.videoId,
                    client: entry.client,
                    options: PlayerRequestOptions(
                        signatureTimestamp: signatureTimestamp,
                        poToken: poToken
                    )
                )

                guard let streamingData = response.streamingData else {
                    lastError = StreamError.noStreams
                    continue
                }

                if let status = response.playabilityStatus?.status, status != "OK" {
                    lastError = StreamError.unplayable(reason: response.playabilityStatus?.reason ?? status)
                    continue
                }

                // Keep HLS as a fallback. VOD responses can expose both an
                // HLS manifest and direct formats; direct URLs start much
                // faster in embedded players. Live responses often expose
                // only HLS, so it remains available below.
                let hlsURL = streamingData.hlsManifestUrl

                let allFormats = (streamingData.formats ?? []) + (streamingData.adaptiveFormats ?? [])

                if let muxed = FormatSelector.bestVideoFormat(from: allFormats) {
                    do {
                        var muxedURL = try await resolveFormatURL(muxed, providers: providers)
                        if let pot = streamingDataPoToken, entry.client.useWebPoTokens {
                            muxedURL = StreamResolver.appendingPoToken(to: muxedURL, pot: pot)
                        }
                        SwiftyTubeLog.debug("[\(entry.client.clientName)] Video resolved as muxed (itag=\(muxed.itag ?? 0))")
                        return .muxed(muxedURL)
                    } catch {
                        lastError = error
                        SwiftyTubeLog.notice("[\(entry.client.clientName)] Failed resolving muxed URL: \(error)")
                    }
                }

                if let video = FormatSelector.bestVideoOnlyFormat(from: allFormats),
                   let audio = FormatSelector.bestAudioFormat(
                       from: allFormats,
                       preference: request.options.audioQuality
                   ) {
                    do {
                        var videoURL = try await resolveFormatURL(video, providers: providers)
                        var audioURL = try await resolveFormatURL(audio, providers: providers)
                        if let pot = streamingDataPoToken, entry.client.useWebPoTokens {
                            videoURL = StreamResolver.appendingPoToken(to: videoURL, pot: pot)
                            audioURL = StreamResolver.appendingPoToken(to: audioURL, pot: pot)
                        }
                        let duration = response.videoDetails?.lengthSeconds.flatMap(Int.init)
                        SwiftyTubeLog.debug("[\(entry.client.clientName)] Video resolved as split (video itag=\(video.itag ?? 0), audio itag=\(audio.itag ?? 0))")
                        return .split(video: videoURL, audio: audioURL, duration: duration)
                    } catch {
                        lastError = error
                        SwiftyTubeLog.notice("[\(entry.client.clientName)] Failed resolving split video: \(error)")
                    }
                }

                if let hlsURL, !hlsURL.isEmpty {
                    SwiftyTubeLog.debug("[\(entry.client.clientName)] Video resolved as HLS")
                    return .hls(hlsURL)
                }
            } catch {
                lastError = error
                SwiftyTubeLog.error("Video resolution failed for \(entry.client.clientName): \(error)")
            }
        }

        throw lastError ?? StreamError.noSuitableFormat
    }

    /// Resolves a single format's stream URL, going through the cipher if needed.
    public static func resolveFormatURL(
        _ format: Format,
        providers: StreamResolveProviders = .none
    ) async throws -> String {
        if let url = format.url, !url.isEmpty { return url }
        if let cipherText = format.signatureCipher ?? format.cipher,
           let cipherURL = providers.cipherURL,
           let playerJs = providers.playerJs {
            return try await cipherURL(cipherText, await playerJs())
        }
        throw StreamError.noStreamUrl
    }

    /// mpv EDL for separate DASH tracks.
    public static func combineVideoAndAudio(videoURL: String, audioURL: String, duration: Int?) -> String {
        let lengthParam = duration.map { ",length=\($0)" } ?? ""
        let video = "%\(videoURL.utf8.count)%\(videoURL)\(lengthParam)"
        let audio = "%\(audioURL.utf8.count)%\(audioURL)\(lengthParam)"
        return "edl://!new_stream;!no_clip;!no_chapters;\(video);!new_stream;!no_clip;!no_chapters;\(audio)"
    }
}
