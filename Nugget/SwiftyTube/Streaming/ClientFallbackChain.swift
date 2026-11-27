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
            FallbackClient(client: .webRemix, skipValidation: false),
            FallbackClient(client: .web, skipValidation: true)
        ]
    }

    /// Fallback chain trying direct clients first, then validated WEB_MUSIC / WEB_REMIX
    /// for 256AAC streams, and WEB last.
    public static var aac256Chain: [FallbackClient] {
        direct + [
            FallbackClient(client: .webMusic, skipValidation: false),
            FallbackClient(client: .webRemix, skipValidation: false),
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
