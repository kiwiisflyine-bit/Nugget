//
//  StreamResolver.swift
//  SwiftyTube
//
//  Created on 03/10/2026.
//

import Foundation

/// Per-call knobs for `StreamResolver.resolve`.
public struct StreamResolveOptions: Sendable {
    /// PoToken for web clients (playerRequestPoToken).
    public var poToken: String?
    /// PoToken appended to stream URLs (`&pot=`).
    public var streamingDataPoToken: String?
    /// Caller-preferred format (used when still present in the response).
    public var preferredFormat: Format?
    public var forDownload: Bool
    public var audioQuality: AudioQuality
    public var downloadQuality: DownloadQuality
    /// Resolution cap for the returned muxed stream.
    public var videoQuality: VideoQuality

    public init(
        poToken: String? = nil,
        streamingDataPoToken: String? = nil,
        preferredFormat: Format? = nil,
        forDownload: Bool = false,
        audioQuality: AudioQuality = .auto,
        downloadQuality: DownloadQuality = .high,
        videoQuality: VideoQuality = .auto
    ) {
        self.poToken = poToken
        self.streamingDataPoToken = streamingDataPoToken
        self.preferredFormat = preferredFormat
        self.forDownload = forDownload
        self.audioQuality = audioQuality
        self.downloadQuality = downloadQuality
        self.videoQuality = videoQuality
    }

    public static let `default` = StreamResolveOptions()
}

/// Optional cipher/PoToken hooks; nil steps are skipped.
public struct StreamResolveProviders: Sendable {
    /// Player.js signature timestamp for clients with `useSignatureTimestamp`.
    public var signatureTimestamp: (@Sendable () async -> Int?)?
    /// (cipherText, playerJs) → URL.
    public var cipherURL: (@Sendable (String, String) async throws -> String)?
    /// Fetches player.js content for cipher resolution.
    public var playerJs: (@Sendable () async throws -> String)?
    /// Called when a stream URL gets HTTP 403 during validation.
    public var onStreamRejection: (@Sendable () async -> Void)?
    /// Tokens per videoId; nil proceeds tokenless.
    public var poTokenProvider: (@Sendable (String) async -> PoTokenResult?)?
    /// Persist hook per resolve. Never throws.
    public var resolvedFormatHandler: (@Sendable (ResolvedFormatInfo) async -> Void)?

    public init(
        signatureTimestamp: (@Sendable () async -> Int?)? = nil,
        cipherURL: (@Sendable (String, String) async throws -> String)? = nil,
        playerJs: (@Sendable () async throws -> String)? = nil,
        onStreamRejection: (@Sendable () async -> Void)? = nil,
        poTokenProvider: (@Sendable (String) async -> PoTokenResult?)? = nil,
        resolvedFormatHandler: (@Sendable (ResolvedFormatInfo) async -> Void)? = nil
    ) {
        self.signatureTimestamp = signatureTimestamp
        self.cipherURL = cipherURL
        self.playerJs = playerJs
        self.onStreamRejection = onStreamRejection
        self.poTokenProvider = poTokenProvider
        self.resolvedFormatHandler = resolvedFormatHandler
    }

    public static let none = StreamResolveProviders()
}

/// Format facts for app persistence.
public struct ResolvedFormatInfo: Sendable {
    public var videoId: String
    public var itag: Int
    public var mimeType: String
    public var codecs: String
    public var bitrate: Int
    public var contentLength: Int64
    public var loudnessDb: Double?
    public var playbackUrl: String?

    public init(
        videoId: String,
        itag: Int,
        mimeType: String,
        codecs: String,
        bitrate: Int,
        contentLength: Int64,
        loudnessDb: Double?,
        playbackUrl: String?
    ) {
        self.videoId = videoId
        self.itag = itag
        self.mimeType = mimeType
        self.codecs = codecs
        self.bitrate = bitrate
        self.contentLength = contentLength
        self.loudnessDb = loudnessDb
        self.playbackUrl = playbackUrl
    }
}

// One client, one /player call.
public enum StreamResolver: Sendable {
    /// Resolves the best stream URL for a video with a specific client.
    public static func resolve(
        videoId: String,
        client: YouTubeClient,
        using innerTube: InnerTubeClient,
        options: StreamResolveOptions = .default,
        providers: StreamResolveProviders = .none
    ) async throws -> PlaybackResult {
        SwiftyTubeLog.debug("Resolving videoId=\(videoId) client=\(client.clientName) v\(client.clientVersion)")

        let signatureTimestamp: Int?
        if client.useSignatureTimestamp {
            signatureTimestamp = await providers.signatureTimestamp?()
            if let timestamp = signatureTimestamp {
                SwiftyTubeLog.debug("Using signatureTimestamp=\(timestamp)")
            }
        } else {
            signatureTimestamp = nil
        }

        let response: PlayerResponse = try await innerTube.playerResponse(
            videoId: videoId,
            client: client,
            options: PlayerRequestOptions(
                signatureTimestamp: signatureTimestamp,
                poToken: options.poToken
            )
        )

        guard let playabilityStatus = response.playabilityStatus else {
            throw StreamError.unplayable(reason: "No playability status in response")
        }

        if playabilityStatus.status != "OK" {
            let reason = playabilityStatus.reason ?? "Unknown"
            let hasFormats = (response.streamingData?.formats?.isEmpty == false) ||
                (response.streamingData?.adaptiveFormats?.isEmpty == false)
            // Tolerate non-OK clients that still return formats.
            guard client.skipPlayerResponseValidation || hasFormats else {
                SwiftyTubeLog.error("[\(client.clientName)] Not playable: status=\(playabilityStatus.status ?? "?") reason=\(reason)")
                throw StreamError.unplayable(reason: reason)
            }
            SwiftyTubeLog.notice("[\(client.clientName)] Status=\(playabilityStatus.status ?? "?") (\(reason)) - attempting formats anyway (hasFormats=\(hasFormats))")
        } else {
            SwiftyTubeLog.debug("[\(client.clientName)] Playable: status=OK")
        }

        guard let streamingData = response.streamingData else {
            throw StreamError.noStreams
        }

        let adaptiveFormats = streamingData.adaptiveFormats ?? []
        SwiftyTubeLog.debug(
            "Got \(adaptiveFormats.count) adaptive formats, expiresIn=\(streamingData.expiresInSeconds ?? "?")s"
        )

        let allFormats = (streamingData.formats ?? []) + adaptiveFormats
        let maxVideoHeight = allFormats.compactMap { $0.height }.max() ?? 0
        let hasVideoContent = maxVideoHeight >= 480
        SwiftyTubeLog.debug(
            "hasVideoContent=\(hasVideoContent) (maxVideoHeight=\(maxVideoHeight), " +
                "video formats: \(allFormats.filter { $0.width != nil }.count))"
        )

        let candidates: [Format]
        if let preferred = options.preferredFormat,
           let fresh = allFormats.first(where: { $0.itag == preferred.itag }) {
            candidates = [fresh]
            SwiftyTubeLog.debug("Using preferred format itag=\(preferred.itag ?? 0)")
        } else if options.forDownload {
            if let downloadFormat = FormatSelector.bestDownloadFormat(
                from: allFormats,
                downloadQuality: options.downloadQuality
            ) {
                candidates = [downloadFormat]
            } else {
                candidates = []
            }
        } else {
            candidates = FormatSelector.candidateAudioFormats(
                from: allFormats,
                preference: options.audioQuality
            )
        }

        var chosenFormat: Format?
        var resolvedStreamUrl: String?
        var lastResolveError: Error?

        for candidate in candidates {
            if let url = candidate.url, !url.isEmpty {
                chosenFormat = candidate
                resolvedStreamUrl = url
                SwiftyTubeLog.debug("Direct URL selected for itag=\(candidate.itag ?? 0): \(url.prefix(120))...")
                break
            } else if let cipherText = candidate.signatureCipher ?? candidate.cipher {
                SwiftyTubeLog.debug("Format itag=\(candidate.itag ?? 0) requires cipher deobfuscation")
                guard let cipherURL = providers.cipherURL, let playerJs = providers.playerJs else {
                    lastResolveError = StreamError.noStreamUrl
                    continue
                }
                do {
                    let playerJsContent = try await playerJs()
                    let url = try await cipherURL(cipherText, playerJsContent)
                    chosenFormat = candidate
                    resolvedStreamUrl = url
                    SwiftyTubeLog.debug("Resolved cipher URL for itag=\(candidate.itag ?? 0): \(url.prefix(120))...")
                    break
                } catch {
                    lastResolveError = error
                    SwiftyTubeLog.notice("Cipher deobfuscation failed for itag=\(candidate.itag ?? 0): \(error). Trying next candidate.")
                }
            }
        }

        // If no direct/ciphered adaptive format worked (e.g. iOS SABR-only formats)
        // and this is playback (not raw file download), fall back to the HLS manifest
        // when provided by the client (such as IOS).
        if chosenFormat == nil,
           !options.forDownload,
           let hlsUrl = streamingData.hlsManifestUrl,
           !hlsUrl.isEmpty {
            let videoDetails = response.videoDetails
            let duration = videoDetails?.lengthSeconds.flatMap(Int.init)
            let musicVideoType = videoDetails?.musicVideoType
            if let duration, let resolvedVideoId = videoDetails?.videoId {
                DurationCache.set(resolvedVideoId, duration)
            }
            return PlaybackResult(
                streamUrl: hlsUrl,
                itag: 0,
                mimeType: "application/x-mpegURL",
                bitrate: 128_000,
                audioQuality: "AUDIO_QUALITY_MEDIUM",
                videoId: videoDetails?.videoId ?? videoId,
                title: videoDetails?.title,
                author: videoDetails?.author,
                duration: duration,
                expiresInSeconds: streamingData.expiresInSeconds.flatMap(Int.init) ?? 0,
                clientName: client.clientName,
                userAgent: client.userAgent,
                musicVideoType: musicVideoType,
                hasVideoContent: hasVideoContent,
                muxedStreamUrl: hlsUrl,
                loudnessDb: nil
            )
        }

        guard let selectedFormat = chosenFormat, let streamUrl = resolvedStreamUrl else {
            let formatInfos = allFormats.map { format in
                "itag=\(format.itag ?? 0) mime=\(format.mimeType ?? "?") audio=\(format.audioChannels != nil) " +
                    "url=\(format.url != nil) cipher=\(format.signatureCipher != nil || format.cipher != nil)"
            }
            SwiftyTubeLog.error("No suitable playable format. Formats: \(formatInfos.joined(separator: ", "))")
            throw lastResolveError ?? StreamError.noSuitableFormat
        }

        var finalStreamUrl = streamUrl
        if let pot = options.streamingDataPoToken, client.useWebPoTokens {
            finalStreamUrl = Self.appendingPoToken(to: finalStreamUrl, pot: pot)
            SwiftyTubeLog.debug("Appended &pot= to stream URL")
        }

        let videoDetails = response.videoDetails
        let duration = videoDetails?.lengthSeconds.flatMap(Int.init)
        let musicVideoType = videoDetails?.musicVideoType

        let muxedFormat = FormatSelector.bestVideoFormat(from: allFormats, preference: options.videoQuality)
        let muxedStreamUrl: String? = {
            guard let videoFormat = muxedFormat,
                  let url = videoFormat.url, !url.isEmpty else {
                return streamingData.hlsManifestUrl
            }
            guard let pot = options.streamingDataPoToken, client.useWebPoTokens else {
                return url
            }
            return Self.appendingPoToken(to: url, pot: pot)
        }()

        let result = PlaybackResult(
            streamUrl: finalStreamUrl,
            itag: selectedFormat.itag ?? 0,
            mimeType: selectedFormat.mimeType ?? "",
            bitrate: selectedFormat.bitrate ?? 0,
            audioQuality: selectedFormat.audioQuality ?? "",
            videoId: videoDetails?.videoId ?? videoId,
            title: videoDetails?.title,
            author: videoDetails?.author,
            duration: duration,
            expiresInSeconds: streamingData.expiresInSeconds.flatMap(Int.init) ?? 0,
            clientName: client.clientName,
            userAgent: client.userAgent,
            musicVideoType: musicVideoType,
            hasVideoContent: hasVideoContent,
            muxedStreamUrl: muxedStreamUrl,
            muxedWidth: muxedFormat?.width,
            muxedHeight: muxedFormat?.height,
            loudnessDb: selectedFormat.loudnessDb
        )
        SwiftyTubeLog.debug("musicVideoType=\(musicVideoType ?? "nil")")

        if let duration, let resolvedVideoId = videoDetails?.videoId {
            DurationCache.set(resolvedVideoId, duration)
        }

        await providers.resolvedFormatHandler?(ResolvedFormatInfo(
            videoId: result.videoId,
            itag: result.itag,
            mimeType: result.mimeType,
            codecs: selectedFormat.codec,
            bitrate: result.bitrate,
            contentLength: (selectedFormat.contentLength as NSString?)?.longLongValue ?? 0,
            loudnessDb: result.loudnessDb,
            playbackUrl: response.playbackTracking?.videostatsPlaybackUrl?.baseUrl
        ))

        SwiftyTubeLog.debug(
            "Result: title=\"\(result.title ?? "?")\" author=\"\(result.author ?? "?")\" " +
                "itag=\(result.itag) quality=\(result.audioQuality) bitrate=\(result.bitrate) client=\(result.clientName)"
        )

        return result
    }

    /// Query-escape incl. +, =, &, /.
    static func encodeQueryValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    /// Appends the po_token with the right separator (cipher-resolved URLs
    /// don't always carry a query string).
    static func appendingPoToken(to url: String, pot: String) -> String {
        url.contains("?") ? "\(url)&pot=\(encodeQueryValue(pot))" : "\(url)?pot=\(encodeQueryValue(pot))"
    }

    /// 1 KiB Range GET check using the resolving client's User-Agent.
    public static func validateStream(
        url: String,
        userAgent: String? = nil,
        session: URLSession = .shared,
        onStreamRejection: (@Sendable () async -> Void)? = nil
    ) async -> Bool {
        guard let url = URL(string: url) else {
            SwiftyTubeLog.error("Invalid URL for validation")
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        if let userAgent, !userAgent.isEmpty {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }

        do {
            let (_, httpResponse) = try await HttpClient.data(for: request, session: session)
            let valid = (200 ... 299).contains(httpResponse.statusCode)
            if !valid {
                SwiftyTubeLog.debug("Range validation: status=\(httpResponse.statusCode) valid=false")
            }
            if httpResponse.statusCode == 403 {
                await onStreamRejection?()
            }
            return valid
        } catch {
            SwiftyTubeLog.error("Range validation failed: \(error.localizedDescription)")
            return false
        }
    }
}
