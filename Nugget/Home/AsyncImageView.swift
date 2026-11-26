//
//  AsyncImageView.swift
//  Nugget
//
//  Created on 01/07/2026.
//

import Nuke
import SwiftUI

struct AsyncImageView: View {
    let url: String?
    var contentMode: ContentMode = .fill
    @Environment(\.displayScale) private var displayScale
    @State private var loadedImage: UIImage?

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let image = loadedImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
                        .clipped()
                } else {
                    placeholderView
                }
            }
            .task(id: "\(url ?? "")|\(contentMode)") {
                await loadImage(targetSize: geometry.size)
            }
        }
    }

    private func loadImage(targetSize: CGSize) async {
        guard let urlString = url, !urlString.isEmpty else {
            loadedImage = nil
            return
        }
        let scale = max(displayScale, 1)
        let rawPixels = max(targetSize.width * scale, targetSize.height * scale)
        let rung = ArtworkURLs.rung(for: rawPixels)
        let normalized = normalizeThumbnailURL(urlString, pixels: rung)
        guard let resolvedURL = URL(string: normalized) else {
            loadedImage = nil
            return
        }

        let targetPx = CGFloat(rung)
        let request: ImageRequest
        if contentMode == .fill {
            request = ImageRequest(
                url: resolvedURL,
                processors: [
                    .resize(
                        size: CGSize(width: targetPx, height: targetPx),
                        unit: .pixels,
                        contentMode: .aspectFill
                    )
                ]
            )
        } else {
            request = ImageRequest(url: resolvedURL)
        }

        do {
            let image = try await ImagePipeline.shared.image(for: request)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                loadedImage = image
            }
        } catch {
            guard !Task.isCancelled else { return }
            loadedImage = nil
        }
    }

    private var placeholderView: some View {
        Image(systemName: "music.note")
            .resizable()
            .scaledToFit()
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGray6))
    }
}

private func normalizeThumbnailURL(_ urlString: String, pixels: Int) -> String {
    if urlString.contains("googleusercontent.com") || urlString.contains("ggpht.com") {
        return ArtworkURLs.artwork(urlString, at: pixels) ?? urlString
    }
    if urlString.contains("i.ytimg.com/vi/"), pixels >= ArtworkURLs.cardPx {
        return ArtworkURLs.sdVariant(urlString) ?? urlString
    }
    return urlString
}
