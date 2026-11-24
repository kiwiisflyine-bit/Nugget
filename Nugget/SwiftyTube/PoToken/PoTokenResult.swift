//
//  PoTokenResult.swift
//  SwiftyTube
//
//  Created on 03/10/2026.
//

import Foundation

public struct PoTokenResult: Sendable, Hashable, Codable {
    public let playerRequestPoToken: String
    public let streamingDataPoToken: String

    public init(playerRequestPoToken: String, streamingDataPoToken: String) {
        self.playerRequestPoToken = playerRequestPoToken
        self.streamingDataPoToken = streamingDataPoToken
    }
}
