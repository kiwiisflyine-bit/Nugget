//
//  FormatSelector.swift
//  SwiftyTube
//
//  Created on 03/10/2026.
//

import Foundation

// Best-format picks. Audio score: quality, channels, codec, bitrate.
// Video prefers H.264 (simulator can't decode VP9).
public enum FormatSelector: Sendable {
    /// Audio-only first, then combined with audio. Nil if none.
    public static func audioBearingFormats(_ formats: [Format]) -> [Format]? {
        var audioFormats = formats.filter { $0.isAudioOnly }
        if audioFormats.isEmpty {
            SwiftyTubeLog.debug("No audio-only formats found - trying combined formats with audio track")
            audioFormats = formats.filter { $0.audioChannels != nil }
        }
        guard !audioFormats.isEmpty else {
            SwiftyTubeLog.debug("No formats with audio track found in \(formats.count) total formats")
            return nil
        }
        return audioFormats
    }

    /// Prefers H.264 (avc/mp4) for compatibility, falling back to the full pool.
    public static func h264PreferredPool(_ formats: [Format], kind: String) -> [Format] {
        let h264 = formats.filter {
            $0.codec.lowercased().contains("avc") || $0.mimeType?.lowercased().contains("mp4") == true
        }
        if h264.isEmpty {
            SwiftyTubeLog.debug("No H.264 \(kind) format; falling back to any \(kind) format")
        }
        return h264.isEmpty ? formats : h264
    }

    private static func hasFetchableSource(_ format: Format) -> Bool {
        (format.url?.isEmpty == false) || format.signatureCipher != nil || format.cipher != nil
    }

    /// Ordered list of candidate audio formats, starting with best match and falling back cleanly.
    public static func candidateAudioFormats(from formats: [Format], preference: AudioQuality = .auto) -> [Format] {
        guard !formats.isEmpty else {
            SwiftyTubeLog.debug("No formats to select from")
            return []
        }

        let audioOnly = formats.filter { $0.isAudioOnly }
        let fetchableAudioOnly = audioOnly.filter { hasFetchableSource($0) }

        let pool: [Format]
        if !fetchableAudioOnly.isEmpty {
            pool = fetchableAudioOnly
        } else {
            let fetchableMuxed = formats.filter {
                !$0.isAudioOnly && $0.audioChannels != nil && hasFetchableSource($0)
            }
            if !fetchableMuxed.isEmpty {
                SwiftyTubeLog.debug(
                    "No fetchable audio-only formats; falling back to \(fetchableMuxed.count) fetchable muxed format(s)"
                )
                pool = fetchableMuxed
            } else {
                guard let audioFormats = audioBearingFormats(formats) else { return [] }
                let fetchable = audioFormats.filter { hasFetchableSource($0) }
                pool = fetchable.isEmpty ? audioFormats : fetchable
            }
        }

        if preference == .aac256 {
            var candidates: [Format] = []
            // Explicitly prioritize itag == 141 (audio/mp4, 256kbps AAC)
            if let itag141 = pool.first(where: { $0.itag == 141 }) {
                candidates.append(itag141)
            }
            // Fall back cleanly to remaining AAC formats sorted by highest bitrate
            let aacFormats = pool.filter { format in
                guard format.itag != 141 else { return false }
                let codec = format.codec.lowercased()
                let mime = format.mimeType?.lowercased() ?? ""
                return codec.contains("mp4a") || codec.contains("aac") || mime.contains("audio/mp4") || mime.contains("aac")
            }.sorted { ($0.bitrate ?? 0) > ($1.bitrate ?? 0) }
            candidates.append(contentsOf: aacFormats)

            // Fall back cleanly to Opus / any remaining audio formats sorted by highest bitrate
            let otherFormats = pool.filter { format in
                !candidates.contains(where: { $0.itag == format.itag })
            }.sorted { ($0.bitrate ?? 0) > ($1.bitrate ?? 0) }
            candidates.append(contentsOf: otherFormats)

            return candidates
        }

        var tierCandidates: [Format] = []
        if preference != .auto {
            let tier = Self.qualityTier(for: preference)
            tierCandidates = pool.filter { Self.qualityRank($0.audioQuality) == tier }
                .sorted { formatScore($0) > formatScore($1) }
        }

        let remaining = pool.filter { format in
            !tierCandidates.contains(where: { $0.itag == format.itag })
        }.sorted { formatScore($0) > formatScore($1) }

        return tierCandidates + remaining
    }

    /// Best audio format, optionally restricted to the user's quality tier first.
    public static func bestAudioFormat(from formats: [Format], preference: AudioQuality = .auto) -> Format? {
        let candidates = candidateAudioFormats(from: formats, preference: preference)
        guard let selected = candidates.first else {
            SwiftyTubeLog.debug("No format could be selected")
            return nil
        }

        SwiftyTubeLog.debug(
            "Selected audio: itag=\(selected.itag ?? 0) quality=\(selected.audioQuality ?? "?")" +
                " channels=\(selected.audioChannels ?? 0) codec=\(selected.codec)" +
                " bitrate=\(selected.bitrate ?? 0)"
        )
        return selected
    }

    /// Maps the user-facing quality preference to the format quality tier.
    private static func qualityTier(for preference: AudioQuality) -> Int {
        switch preference {
        case .aac256: return 4
        case .high: return 3
        case .medium: return 2
        case .low: return 1
        case .auto: return 0
        }
    }

    /// Maps a format's `AUDIO_QUALITY_*` string to a comparable tier.
    static func qualityRank(_ quality: String?) -> Int {
        switch quality {
        case "AUDIO_QUALITY_HIGH": return 3
        case "AUDIO_QUALITY_MEDIUM": return 2
        case "AUDIO_QUALITY_LOW": return 1
        default: return 0
        }
    }

    /// Best audio for downloads. `.standard` caps near the target, picks smallest.
    public static func bestDownloadFormat(
        from formats: [Format],
        downloadQuality: DownloadQuality = .high,
        standardTargetBitrate: Int = 96_000
    ) -> Format? {
        guard !formats.isEmpty else {
            SwiftyTubeLog.debug("No formats to select from (download)")
            return nil
        }

        guard let audioFormats = audioBearingFormats(formats) else { return nil }

        // Prefer formats we can actually fetch (direct URL or cipher).
        let fetchable = audioFormats.filter { hasFetchableSource($0) }
        let candidates = fetchable.isEmpty ? audioFormats : fetchable

        let aacFormats = candidates.filter { format in
            let codec = format.codec.lowercased()
            let mime = format.mimeType?.lowercased() ?? ""
            return codec.contains("mp4a") || codec.contains("aac") || mime.contains("audio/mp4") || mime.contains("aac")
        }

        var pool = aacFormats.isEmpty ? candidates : aacFormats
        SwiftyTubeLog.debug(
            "Download pool: \(pool.count) format(s)\(aacFormats.isEmpty ? " (no AAC, falling back to Opus)" : " (AAC preferred)")"
        )

        if downloadQuality == .aac256 {
            // Explicitly prioritize itag == 141 (audio/mp4, 256kbps AAC)
            if let itag141 = candidates.first(where: { $0.itag == 141 }) {
                SwiftyTubeLog.debug("Download selected: itag=141 (256 AAC highest)")
                return itag141
            }
            // Fall back cleanly to the next highest available M4A/AAC or Opus audio stream
            if let bestAAC = aacFormats.max(by: { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }) {
                SwiftyTubeLog.debug("Download: itag 141 unavailable, falling back to next highest AAC itag=\(bestAAC.itag ?? 0)")
                return bestAAC
            }
            if let bestAny = candidates.max(by: { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }) {
                SwiftyTubeLog.debug("Download: falling back to next highest audio itag=\(bestAny.itag ?? 0)")
                return bestAny
            }
        }

        if downloadQuality == .standard {
            let capped = pool.filter { ($0.bitrate ?? standardTargetBitrate) <= standardTargetBitrate + 32_000 }
            if !capped.isEmpty {
                pool = capped
            }
        }

        let selected: Format?
        if downloadQuality == .standard {
            selected = pool.min { ($0.bitrate ?? Int.max) < ($1.bitrate ?? Int.max) }
        } else {
            selected = pool.max { formatScore($0) < formatScore($1) }
        }

        if let selected {
            SwiftyTubeLog.debug(
                "Download selected: itag=\(selected.itag ?? 0) codec=\(selected.codec) bitrate=\(selected.bitrate ?? 0)"
            )
        }

        return selected
    }

    private static func formatScore(_ format: Format) -> Int {
        let qualityScore = qualityRank(format.audioQuality) * 10_000
        let channelsScore = (format.audioChannels ?? 2) * 1_000
        let codecScore = scoreCodec(format.codec) * 100
        let bitrateScore = (format.bitrate ?? 0) / 1000
        return qualityScore + channelsScore + codecScore + bitrateScore
    }

    private static func scoreCodec(_ codec: String) -> Int {
        let lowercased = codec.lowercased()
        if lowercased.contains("opus") { return 2 }
        if lowercased.contains("mp4a") || lowercased.contains("aac") { return 1 }
        return 0
    }

    // MARK: - Video Format Selection

    /// Best muxed (video+audio) format: highest resolution, H.264 first.
    /// `preference` caps the resolution to the nearest height at or below it.
    public static func bestVideoFormat(from formats: [Format], preference: VideoQuality = .auto) -> Format? {
        guard !formats.isEmpty else {
            SwiftyTubeLog.debug("No formats to select from (video)")
            return nil
        }

        let muxedFormats = formats.filter {
            !$0.isAudioOnly
                && $0.width != nil && $0.height != nil
                && $0.audioChannels != nil
                && hasFetchableSource($0)
        }

        guard !muxedFormats.isEmpty else {
            SwiftyTubeLog.debug("No muxed (audio+video) formats found in \(formats.count) total formats")
            return nil
        }

        SwiftyTubeLog.debug("Selecting from \(muxedFormats.count) muxed video formats")

        let pool = h264PreferredPool(muxedFormats, kind: "muxed")

        let selected = selectByHeight(pool, preference: preference) { videoFormatScore($0) }

        if let selected {
            SwiftyTubeLog.debug(
                "Selected video: itag=\(selected.itag ?? 0) resolution=\(selected.width ?? 0)x\(selected.height ?? 0) " +
                    "codec=\(selected.codec) bitrate=\(selected.bitrate ?? 0)"
            )
        }

        return selected
    }

    /// Highest-scoring format at or below the preference height; when nothing
    /// fits (only larger streams exist), the smallest one above it.
    static func selectByHeight(
        _ formats: [Format],
        preference: VideoQuality,
        score: (Format) -> Int
    ) -> Format? {
        guard let target = preference.height else {
            return formats.max { score($0) < score($1) }
        }
        let atOrBelow = formats.filter { ($0.height ?? 0) <= target }
        if atOrBelow.isEmpty {
            return formats.min { ($0.height ?? Int.max) < ($1.height ?? Int.max) }
        }
        return atOrBelow.max { score($0) < score($1) }
    }

    /// Best DASH video-only format: highest resolution, H.264 preferred for
    /// compatibility (software VP9 stalls low-end devices and the simulator
    /// cannot decode it at all).
    public static func bestVideoOnlyFormat(from formats: [Format]) -> Format? {
        guard !formats.isEmpty else {
            SwiftyTubeLog.debug("No formats to select from (video-only)")
            return nil
        }

        let videoOnlyFormats = formats.filter {
            !$0.isAudioOnly
                && $0.width != nil && $0.height != nil
                && $0.audioChannels == nil
                && hasFetchableSource($0)
        }

        guard !videoOnlyFormats.isEmpty else {
            SwiftyTubeLog.debug("No video-only formats found in \(formats.count) total formats")
            return nil
        }

        SwiftyTubeLog.debug("Selecting from \(videoOnlyFormats.count) video-only formats")

        let pool = h264PreferredPool(videoOnlyFormats, kind: "video-only")

        let selected = pool.max { a, b in
            videoFormatScore(a) < videoFormatScore(b)
        }

        if let selected {
            SwiftyTubeLog.debug(
                "Selected video-only: itag=\(selected.itag ?? 0)"
                    + " resolution=\(selected.width ?? 0)x\(selected.height ?? 0)"
                    + " codec=\(selected.codec) bitrate=\(selected.bitrate ?? 0)"
            )
        }

        return selected
    }

    private static func videoFormatScore(_ format: Format) -> Int {
        let widthScore = (format.width ?? 0) * 10
        let heightScore = (format.height ?? 0) * 10
        let bitrateScore = (format.bitrate ?? 0) / 1000
        return widthScore + heightScore + bitrateScore
    }
}
