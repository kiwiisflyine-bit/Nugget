//
//  PlaybackQueue.swift
//  Nugget
//
// 
//

import Foundation

/// Shared queue setup + resolve-and-play flows used by every tap-to-play site.
/// Each entry sets the queue on `NowPlaying` and resolves the stream via
/// `PlaybackManager`, logging failures instead of going silent.
@MainActor
enum PlaybackQueue {
    /// Plays `songs[startIndex]` (clamped). Used by detail play-all / play-song.
    static func play(_ songs: [SongItem], startIndex: Int = 0, log: AppLogger, context: String) {
        guard !songs.isEmpty else { return }
        let index = min(max(startIndex, 0), songs.count - 1)
        NowPlaying.shared.setQueue(songs, startIndex: index)
        NowPlaying.shared.playCurrentSong(logContext: context)
    }

    /// Shuffled variant of `play(_:startIndex:)`.
    static func playShuffled(_ songs: [SongItem], log: AppLogger, context: String) {
        guard !songs.isEmpty else { return }
        play(songs.shuffled(), log: log, context: context)
    }

    /// Plays `song`, reusing `songs` as the queue when it contains it.
    static func play(_ song: SongItem, in songs: [SongItem], log: AppLogger, context: String) {
        if let index = songs.firstIndex(where: { $0.videoId == song.videoId }) {
            play(songs, startIndex: index, log: log, context: context)
        } else {
            play([song], log: log, context: context)
        }
    }

    /// Starts a radio queue for `song`: plays it first unless already current,
    /// then replaces the queue with the fetched radio anchored to `song.videoId`.
    static func startRadio(for song: SongItem, options: RadioOptions = .default) {
        let isCurrentSong = NowPlaying.shared.videoId == song.videoId
        if !isCurrentSong {
            NowPlaying.shared.setQueue([song], startIndex: 0)
            NowPlaying.shared.playCurrentSong(logContext: "startRadio")
        }
        Task {
            guard let radio = try? await PersonalizationService.shared.fetchRadio(videoId: song.videoId, options: options),
                  !radio.songs.isEmpty else { return }
            guard NowPlaying.shared.videoId == song.videoId else { return }
            applyRadioQueue(radio.songs, anchoredTo: song, preferredIndex: radio.currentIndex)
        }
    }

    /// Plays a single song, then continues with its radio queue when available.
    /// Used by Home/Search/Explore tap-to-play.
    static func playSingleWithRadio(_ song: SongItem, log: AppLogger) {
        NowPlaying.shared.setQueue([song], startIndex: 0)
        NowPlaying.shared.playCurrentSong(logContext: "playSingleWithRadio")
        Task { @MainActor in
            guard let radio = try? await PersonalizationService.shared.fetchRadio(videoId: song.videoId),
                  !radio.songs.isEmpty,
                  NowPlaying.shared.videoId == song.videoId else { return }
            applyRadioQueue(radio.songs, anchoredTo: song, preferredIndex: radio.currentIndex)
        }
    }

    private static func applyRadioQueue(
        _ rawSongs: [SongItem],
        anchoredTo song: SongItem,
        preferredIndex: Int
    ) {
        var merged = preservingArtists(rawSongs, over: NowPlaying.shared.queueSongs)
        let targetIndex: Int
        if let existingIndex = merged.firstIndex(where: { $0.videoId == song.videoId }) {
            targetIndex = existingIndex
        } else {
            let clamped = min(max(preferredIndex, 0), merged.count)
            merged.insert(song, at: clamped)
            targetIndex = clamped
        }
        NowPlaying.shared.queueSongs = merged
        NowPlaying.shared.queueIndex = targetIndex
        NowPlaying.shared.persistQueueState()
    }

    private static func preservingArtists(_ songs: [SongItem], over current: [SongItem]) -> [SongItem] {
        guard !current.isEmpty else { return songs }
        let existingById = Dictionary(uniqueKeysWithValues: current.map { ($0.videoId, $0) })
        return songs.map { song in
            guard let old = existingById[song.videoId], old.artists.count > song.artists.count else { return song }
            var merged = song
            merged.artists = old.artists
            return merged
        }
    }
}
