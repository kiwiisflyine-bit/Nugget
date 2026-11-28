//
//  SwiftyTubeShared.swift
//  Nugget
//
//  Created on 03/10/2026.
//

import Foundation

/// Shared InnerTube client for the music service (replaces `InnerTube.shared`).
extension InnerTubeClient {
    static let nuggetShared = InnerTubeClient(config: .music)
    static let tropShared = nuggetShared
    static let streamShared = InnerTubeClient(config: .music)

    /// Updates streamShared with active cookies from the Premium Stream Account,
    /// falling back to the Primary Account if Premium is not logged in.
    static func updateStreamAuth() async {
        let premiumStore = CookieStore.premium
        let primaryStore = CookieStore.primary
        if await premiumStore.isLoggedIn() {
            await streamShared.loadState(from: premiumStore)
        } else {
            await streamShared.loadState(from: primaryStore)
        }
        await streamShared.syncNuggetLocale()
        await StreamCache.shared.clear()
    }
}

extension CookieStore: AuthStateProvider {}

/// Mirrors the old behavior of reading the region from settings per request.
extension InnerTubeClient {
    func syncNuggetLocale() {
        let country = SettingsStore.shared.contentCountry
        updateLocale(YouTubeLocale(gl: country.isEmpty ? "US" : country, hl: "en"))
    }
    func syncTropLocale() {
        syncNuggetLocale()
    }
}

/// Live cipher/PoToken/format-sink wiring for stream resolution.
extension StreamResolveProviders {
    static var nuggetLive: StreamResolveProviders {
        var providers = StreamResolveProviders.live
        providers.poTokenProvider = { videoId in
            try? await PoTokenGenerator.shared.generate(
                videoId: videoId,
                sessionId: PlaybackManager.sessionId
            )
        }
        providers.resolvedFormatHandler = { info in
            _ = try? await DatabaseService.shared.insertOrReplace(FormatEntity(
                id: info.videoId,
                itag: info.itag,
                mimeType: info.mimeType,
                codecs: info.codecs,
                bitrate: info.bitrate,
                sampleRate: 0,
                contentLength: info.contentLength,
                loudnessDb: info.loudnessDb,
                perceptualLoudnessDb: nil,
                playbackUrl: info.playbackUrl
            ))
        }
        return providers
    }
    static var tropLive: StreamResolveProviders {
        nuggetLive
    }
}
