//
//  PlayerHeaderViews.swift
//  Nugget
//
//  Created on 2/07/2026.
//

import SwiftUI

/// Title + artist marquee block shared by the FullPlayer, Queue and Lyrics
/// header rows with audio quality badge support.
struct PlayerTitleBlock: View {
    var title: String
    var artist: String
    var spacing: CGFloat = 2
    var titleFont: Font = .body.weight(.semibold)
    var titleHeight: CGFloat = 24
    var titleColor: Color = .white
    var artistColor: Color? = nil
    var badge: String? = nil
    var is256AAC: Bool = false
    var resetKey: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            HStack(alignment: .center, spacing: 6) {
                MarqueeText(
                    text: title,
                    font: titleFont,
                    frameHeight: titleHeight,
                    textColor: titleColor
                )
                .id("\(resetKey)|\(title)")

                if let badge, !badge.isEmpty {
                    AudioQualityBadge(badge: badge, is256AAC: is256AAC, isPlayerSurface: true)
                }
            }

            if !artist.isEmpty {
                Text(artist)
                    .font(.subheadline)
                    .foregroundStyle(artistColor ?? titleColor.opacity(0.7))
                    .lineLimit(1)
            }
        }
    }
}

/// Heart toggle for player surfaces (FullPlayer, Queue, Lyrics).
struct PlayerLikeButton: View {
    var isLiked: Bool
    var activeColor: Color = .red
    var inactiveColor: Color = .white
    var fontSize: CGFloat = 17
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: isLiked ? "heart.fill" : "heart")
                .font(.system(size: fontSize, weight: .regular))
                .foregroundStyle(isLiked ? activeColor : inactiveColor)
                .frame(width: 36, height: 36)
        }
    }
}

/// ⋮ button for player surfaces. The options sheet stays owned by the caller.
struct PlayerOptionsButton: View {
    var color: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("⋮")
                .font(.system(size: 20, weight: .black))
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
        }
        .accessibilityLabel("Song options")
    }
}
