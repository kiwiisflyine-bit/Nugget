//
//  ClientFallbackChain.swift
//  SwiftyTube
//
//  Created on 03/10/2026.
//

import Foundation

/// Wrapper for a YouTubeClient with validation skip flag.
public struct FallbackClient: Sendable, Hashable {
    public let client: YouTubeClient
    public let skipValidation: Bool

    public init(client: YouTubeClient, skipValidation: Bool) {
        self.client = client
        self.skipValidation = skipValidation
    }
}

/// Clients to try in order; first valid URL wins.
public enum ClientFallbackChain: Sendable {
    /// Direct-URL clients first, token-backed web clients last.
    private static let direct: [FallbackClient] = [
        FallbackClient(client: .visionOS, skipValidation: false),
        FallbackClient(client: .androidVr1_65_10, skipValidation: false),
        FallbackClient(client: .androidVr1_61_48, skipValidation: false),
        FallbackClient(client: .androidVr1_43_32, skipValidation: false),
        FallbackClient(client: .tvHtml5SimplyEmbedded, skipValidation: false),
        FallbackClient(client: .iOS, skipValidation: true),
        FallbackClient(client: .tvHtml5, skipValidation: false),
        FallbackClient(client: .mobile, skipValidation: false)
    ]

    /// Fallback chain for YouTube Music playback.
    public static var preferred: [FallbackClient] {
        direct + [
            FallbackClient(client: .webRemix, skipValidation: true),
            FallbackClient(client: .web, skipValidation: true)
        ]
    }

    /// Fallback chain prioritizing WEB_MUSIC desktop context for 256AAC stream resolution,
    /// falling back to direct clients and WEB desktop client for non-256 AAC and general YouTube clips.
    public static var aac256Chain: [FallbackClient] {
        [
            FallbackClient(client: .webMusic, skipValidation: true),
            FallbackClient(client: .webRemix, skipValidation: true)
        ] + direct + [
            FallbackClient(client: .web, skipValidation: true)
        ]
    }

    /// Fallback chain for main-YouTube playback.
    public static var youtube: [FallbackClient] {
        direct + [FallbackClient(client: .web, skipValidation: true)]
    }

    /// Chain for downloads, supporting both 256AAC and non-256/general formats.
    public static var forDownload: [FallbackClient] {
        preferred
    }
}
