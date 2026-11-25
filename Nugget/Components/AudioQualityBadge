//
//  AudioQualityBadge.swift
//  Nugget
//
//  Created on 25/11/2026.
//

import SwiftUI

public enum AudioQualityBadgeHelper {
    public static func codecName(itag: Int?, mimeType: String?, codec: String?) -> String {
        if itag == 141 || itag == 140 || itag == 256 || itag == 258 {
            return "AAC"
        }
        if itag == 251 || itag == 250 || itag == 249 {
            return "OPUS"
        }
        let raw = (codec ?? mimeType ?? "").lowercased()
        if raw.contains("mp4a") || raw.contains("aac") || raw.contains("audio/mp4") {
            return "AAC"
        }
        if raw.contains("opus") || raw.contains("webm") {
            return "OPUS"
        }
        return "AAC"
    }

    public static func bitrateKbps(itag: Int?, bitrate: Int?) -> Int {
        if itag == 141 { return 256 }
        if itag == 140 { return 128 }
        if itag == 251 { return 160 }
        if itag == 250 { return 70 }
        if itag == 249 { return 50 }
        if let bitrate, bitrate > 0 {
            return (bitrate + 500) / 1000
        }
        return 128
    }

    public static func is256AAC(itag: Int?, mimeType: String? = nil, codec: String? = nil, bitrate: Int? = nil) -> Bool {
        if itag == 141 { return true }
        let c = codecName(itag: itag, mimeType: mimeType, codec: codec)
        let b = bitrateKbps(itag: itag, bitrate: bitrate)
        return c == "AAC" && b >= 256
    }

    public static func badgeText(itag: Int?, mimeType: String? = nil, codec: String? = nil, bitrate: Int? = nil) -> String {
        let c = codecName(itag: itag, mimeType: mimeType, codec: codec)
        let b = bitrateKbps(itag: itag, bitrate: bitrate)
        return "\(b)\(c)"
    }
}

/// Compact rounded-corner pill badge displaying audio codec and bitrate.
/// Uses the app's defined theme accent color with contrasting text for 256kbps AAC (itag 141),
/// and a subtle grey shaded background for normal/standard audio qualities.
struct AudioQualityBadge: View {
    let badge: String
    let is256AAC: Bool
    var isPlayerSurface: Bool = false
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        Text(badge)
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .textCase(.uppercase)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .foregroundStyle(is256AAC ? Color.white : (isPlayerSurface ? Color.white.opacity(0.85) : Color.secondary))
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(is256AAC ? settings.accentColor : (isPlayerSurface ? Color.white.opacity(0.18) : Color(.systemGray5)))
            )
            .fixedSize()
    }
}
