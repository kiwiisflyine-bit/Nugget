//
//  FullPlayerView.swift
//  Nugget
//
//  
//

import SwiftUI
import UIKit

struct FullPlayerView: View {
    let onCollapse: () -> Void

    @Environment(SettingsStore.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    private let player = PlayerController.shared
    @Bindable private var np = NowPlaying.shared
    @State private var editingProgress: Float = 0
    @State private var isEditingSlider = false
    @State private var collapseOffset: CGFloat = 0

    @ObservedObject private var likeStore = LikeStore.shared
    private var isLiked: Bool {
        guard let song = np.currentSong else { return false }
        return likeStore.isLiked(videoId: song.videoId)
    }
    @State private var showLyrics = false
    @State private var showQueue = false
    @State private var pendingRoute: DetailRoute?
    @State private var showSongMenu = false
    @State private var artworkEntryOffset: CGFloat = 0
    @State private var canvasDominantColors: [Color]?

    private var isLightTheme: Bool {
        !(np.isVideoMode && np.hasVideo)
            && settings.playerBackgroundStyle != .solid
            && colorScheme == .light
    }

    private var primaryForeground: Color {
        isLightTheme ? Color(red: 0.08, green: 0.08, blue: 0.1) : .white
    }

    private var secondaryForeground: Color {
        isLightTheme ? Color(red: 0.08, green: 0.08, blue: 0.1).opacity(0.65) : .white.opacity(0.65)
    }

    private var playerBackgroundColors: [Color] {
        let baseAccent = (canvasDominantColors ?? np.dominantColors).first
            ?? Color(red: 0.22, green: 0.22, blue: 0.28)
        if colorScheme == .light {
            let lightBase = Color(red: 0.95, green: 0.95, blue: 0.97)
            return [
                baseAccent.opacity(0.26),
                lightBase
            ]
        } else {
            let darkBase = Color(red: 0.08, green: 0.08, blue: 0.10)
            return [
                baseAccent.opacity(0.45),
                darkBase
            ]
        }
    }

    private var artworkAspectRatio: CGFloat {
        guard let uiImage = np.thumbnailUIImage, uiImage.size.height > 0 else {
            return 1
        }
        let ratio = uiImage.size.width / uiImage.size.height
        return max(0.75, min(1.78, ratio))
    }

    var body: some View {
        GeometryReader { geometry in
            let horizontalPadding: CGFloat = geometry.size.width < 375 ? 24 : 32
            let isCompact = geometry.size.height < 700
            let maxCardHeight = min(
                geometry.size.height * (isCompact ? 0.34 : 0.40),
                360
            )

            ZStack {
                if np.isVideoMode && np.hasVideo {
                    Color.black
                        .ignoresSafeArea()
                } else if settings.playerBackgroundStyle == .solid {
                    (colorScheme == .light ? Color.white : Color.black)
                        .ignoresSafeArea()
                } else {
                    LinearGradient(
                        colors: playerBackgroundColors,
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()
                    .animation(.easeInOut(duration: 0.6), value: np.videoId)
                    .overlay(alignment: .top) {
                        Circle()
                            .fill(playerBackgroundColors.first ?? .blue)
                            .frame(width: 420, height: 420)
                            .blur(radius: 120)
                            .opacity(colorScheme == .light ? 0.28 : 0.42)
                            .offset(y: -150)
                            .allowsHitTesting(false)
                    }
                }

                VStack(spacing: 0) {
                    Capsule()
                        .fill(primaryForeground.opacity(0.28))
                        .frame(width: 36, height: 5)
                        .padding(.top, 14)
                        .padding(.bottom, 12)
                        .contentShape(Rectangle().size(width: 60, height: 30))
                        .onTapGesture {
                            guard showLyrics else { return }
                            withAnimation(.easeInOut(duration: 0.3)) {
                                showLyrics = false
                            }
                        }
                        .accessibilityLabel(showLyrics ? "Close lyrics" : "Collapse player")

                    if showLyrics {
                        LyricsView(
                            showLyrics: $showLyrics,
                            pendingRoute: $pendingRoute,
                            progressSlider: { progressSlider(horizontalPadding: horizontalPadding) }
                        )
                    } else if np.isVideoMode && np.hasVideo {
                        musicVideoContent
                    } else if showQueue {
                        QueueView(
                            showQueue: $showQueue,
                            isShuffleOn: $np.isShuffleOn,
                            isRepeatOn: $np.isRepeatOn,
                            editingProgress: $editingProgress,
                            isEditingSlider: $isEditingSlider,
                            pendingRoute: $pendingRoute,
                            progressSlider: { progressSlider(horizontalPadding: horizontalPadding) }
                        )
                    } else {
                        Spacer(minLength: isCompact ? 6 : 14)

                        artworkCard(maxHeight: maxCardHeight, horizontalPadding: horizontalPadding)

                        Spacer(minLength: isCompact ? 10 : 18)

                        titleAndActionsRow
                            .foregroundStyle(primaryForeground)
                            .padding(.horizontal, horizontalPadding)
                            .padding(.bottom, isCompact ? 10 : 14)

                        progressSlider(horizontalPadding: horizontalPadding)
                            .padding(.top, 2)
                            .padding(.bottom, isCompact ? 8 : 12)

                        PlaybackControlsRow(
                            isPlaying: np.isPlaying,
                            hasPrevious: np.hasPrevious,
                            hasNext: np.hasNext,
                            onPrevious: { np.playPrevious() },
                            onPlayPause: { player.togglePlayPause() },
                            onNext: { np.playNext() }
                        )
                        .foregroundStyle(primaryForeground)
                        .scaleEffect(isCompact ? 0.94 : 1)
                        .padding(.bottom, isCompact ? 4 : 10)

                        HStack(spacing: 24) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    showLyrics.toggle()
                                }
                            } label: {
                                Image(systemName: showLyrics ? "quote.bubble.fill" : "quote.bubble")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(showLyrics ? primaryForeground : secondaryForeground)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Lyrics")

                            SecondaryActionsRow(
                                showQueue: $showQueue,
                                isRepeatOn: $np.isRepeatOn
                            )
                            .foregroundStyle(secondaryForeground)
                        }
                        .scaleEffect(isCompact ? 0.94 : 1)

                        Spacer(minLength: isCompact ? 6 : 12)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .offset(y: collapseOffset)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: collapseOffset)
            .animation(.easeInOut(duration: 0.35), value: showQueue)
            .simultaneousGesture(collapseDrag)
            .onChange(of: np.videoId) { _, _ in
                np.isVideoMode = false
                showLyrics = false
                showQueue = false
                preloadLyrics()
            }
            .onChange(of: np.queueSongs.count) { _, _ in
                np.preloadNeighborArtwork()
                preloadLyrics()
            }
            .onChange(of: np.queueIndex) { _, _ in
                np.preloadNeighborArtwork()
            }
            .onChange(of: showQueue) { _, newValue in
                if newValue { np.preloadNeighborArtwork() }
            }
            .task { np.preloadNeighborArtwork() }
            .task(id: np.videoId) { preloadLyrics() }
            .sheet(isPresented: $showSongMenu) {
                if let song = np.currentSong {
                    PlayerMenuSheet(song: song, onCollapseRequest: { onCollapse() })
                }
            }
            .background(
                Color.clear
                    .detailRouteSheet(item: $pendingRoute)
            )
        }
    }

    // MARK: - Gestures

    /// Swipe left/right on the artwork to skip tracks (toggleable in Settings).
    /// Blocked at the queue's ends (no movement); on skip, the incoming
    /// artwork slides in from the swipe direction.
    private var artworkSwipe: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                guard settings.artworkSwipeNavigation else { return }
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if value.translation.width < -60, np.hasNext {
                    np.playNext()
                    slideInArtwork(fromLeft: false)
                } else if value.translation.width > 60, np.hasPrevious {
                    np.playPrevious()
                    slideInArtwork(fromLeft: true)
                }
            }
    }

    private func slideInArtwork(fromLeft: Bool) {
        artworkEntryOffset = fromLeft ? -600 : 600
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            artworkEntryOffset = 0
        }
    }

    /// Swipe down anywhere to collapse. Vertical-dominant drags only.
    private var collapseDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard value.translation.height > 0,
                      value.translation.height > abs(value.translation.width) else { return }
                collapseOffset = value.translation.height
            }
            .onEnded { value in
                defer { collapseOffset = 0 }
                let isVertical = value.translation.height > abs(value.translation.width)
                if isVertical, value.translation.height > 140 {
                    onCollapse()
                }
            }
    }

    // MARK: - Player Content

    private func preloadLyrics() {
        guard let id = np.videoId else { return }
        let upcoming = np.upcomingSongs(prefixLimit: 3).map(\.videoId)
        Task { await LyricsService.shared.preload(videoId: id, upcoming: upcoming) }
    }

    private var titleAndActionsRow: some View {
        HStack(alignment: .center, spacing: 12) {
            PlayerTitleBlock(
                title: np.title,
                artist: np.displayArtist,
                spacing: 4,
                titleFont: .title3.weight(.bold),
                titleHeight: 28,
                badge: np.audioBadge,
                is256AAC: np.is256AAC
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            HStack(spacing: 8) {
                PlayerLikeButton(isLiked: isLiked) {
                    guard let song = np.currentSong else { return }
                    Task { await likeStore.toggle(song: song) }
                }

                if np.currentSong != nil {
                    PlayerOptionsButton {
                        showSongMenu = true
                    }
                }
            }
        }
    }

    private var musicVideoContent: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        np.isVideoMode = false
                        showQueue = false
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.48), in: Circle())
                }
                .accessibilityLabel("Return to artwork player")

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            musicVideoStage

            QueueView(
                showQueue: $showQueue,
                isShuffleOn: $np.isShuffleOn,
                isRepeatOn: $np.isRepeatOn,
                editingProgress: $editingProgress,
                isEditingSlider: $isEditingSlider,
                pendingRoute: $pendingRoute,
                progressSlider: { progressSlider(horizontalPadding: 32) },
                isVideoMode: true
            )
            .frame(maxHeight: .infinity)
        }
    }

    private var musicVideoStage: some View {
        ZStack {
            VideoPlayerView()
            if !np.isVideoReady {
                artworkImage
                    .transition(.opacity)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .animation(.easeOut(duration: 0.2), value: np.isVideoReady)
    }

    private func artworkCard(maxHeight: CGFloat, horizontalPadding: CGFloat) -> some View {
        let cornerRadius: CGFloat = 16
        return ZStack {
            artworkImage
            CanvasVideoView(
                videoId: np.videoId,
                title: np.title,
                artist: np.artist,
                album: np.albumTitle.isEmpty ? nil : np.albumTitle,
                isPlaying: np.isPlaying,
                enabled: settings.canvasEnabled,
                onDominantColorsChange: { canvasDominantColors = $0 }
            )
        }
        .aspectRatio(artworkAspectRatio, contentMode: .fit)
        .frame(maxHeight: maxHeight)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(
            color: Color.black.opacity(colorScheme == .light ? 0.18 : 0.42),
            radius: 22,
            x: 0,
            y: 12
        )
        .scaleEffect(np.isPlaying ? 1.0 : 0.75)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: np.isPlaying)
        .offset(x: artworkEntryOffset)
        .gesture(artworkSwipe)
        .onTapGesture {
            guard np.hasVideo else { return }
            showQueue = true
            player.setVideoMode()
        }
        .padding(.horizontal, horizontalPadding)
    }

    /// Song artwork (or placeholder), preserving natural aspect ratio cleanly.
    private var artworkImage: some View {
        Group {
            if let uiImage = np.thumbnailUIImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(primaryForeground.opacity(0.1))
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 56))
                            .foregroundStyle(secondaryForeground)
                    }
            }
        }
    }

    private func progressSlider(horizontalPadding: CGFloat) -> some View {
        VStack(spacing: 6) {
            ProgressBar(
                progress: Binding(
                    get: { isEditingSlider ? editingProgress : np.progress },
                    set: { editingProgress = $0 }
                ),
                accentColor: playerBackgroundColors.first ?? primaryForeground,
                isPlaying: np.isPlaying,
                onEditingChanged: { editing in
                    if editing {
                        editingProgress = np.progress
                    } else {
                        let target = TimeInterval(editingProgress) * np.duration
                        player.seek(to: target)
                        np.currentTime = target
                        player.updateNowPlayingProgress()
                    }
                    isEditingSlider = editing
                }
            )

            HStack {
                Text(DurationFormat.playbackTime(isEditingSlider
                    ? TimeInterval(editingProgress) * np.duration
                    : np.currentTime))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(secondaryForeground)

                Spacer()

                Text(DurationFormat.playbackTime(np.duration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(secondaryForeground)
            }
        }
        .padding(.horizontal, horizontalPadding)
    }
}
