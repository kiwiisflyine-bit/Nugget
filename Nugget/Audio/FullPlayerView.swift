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
    @Environment(\.colorScheme) private var environmentColorScheme
    @ObservedObject private var downloadManager = DownloadManager.shared
    private let player = PlayerController.shared
    @Bindable private var np = NowPlaying.shared
    @AppStorage("fullPlayer.audioBadgeHidden") private var isAudioBadgeHiddenByUser = false
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

    private var currentTrackDownload: DownloadedTrackEntity? {
        guard let videoId = np.videoId else { return nil }
        return downloadManager.track(for: videoId)
    }

    private var isCurrentSongDownloaded: Bool {
        guard let videoId = np.videoId else { return false }
        return downloadManager.isDownloaded(videoId: videoId)
    }

    private var effectiveIs256AAC: Bool {
        if let track = currentTrackDownload {
            return track.is256AAC
        }
        return np.is256AAC
    }

    private var effectiveAudioBadge: String? {
        if let track = currentTrackDownload, let badge = track.audioBadgeText {
            return badge
        }
        return np.audioBadge
    }

    private var activeColorScheme: ColorScheme {
        settings.preferredColorScheme ?? environmentColorScheme
    }

    private var isLightTheme: Bool {
        !(np.isVideoMode && np.hasVideo) && activeColorScheme == .light
    }

    private var primaryForeground: Color {
        isLightTheme ? .black : .white
    }

    private var secondaryForeground: Color {
        isLightTheme ? Color.black.opacity(0.65) : Color.white.opacity(0.65)
    }

    private var accentSeedColor: Color {
        (canvasDominantColors ?? np.dominantColors).first
            ?? Color(red: 0.22, green: 0.22, blue: 0.28)
    }

    private var tintedBackgroundGradient: LinearGradient {
        if activeColorScheme == .light {
            let base = Color(red: 0.96, green: 0.96, blue: 0.98)
            return LinearGradient(
                colors: [
                    accentSeedColor.opacity(0.32).blended(over: base),
                    base
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            let base = Color(red: 0.07, green: 0.07, blue: 0.09)
            return LinearGradient(
                colors: [
                    accentSeedColor.opacity(0.48).blended(over: base),
                    base
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var blurOverlay: LinearGradient {
        let blur = min(max(settings.playerBlurIntensity, 0), 1)
        let seeThrough = min(max(settings.playerTransparentIntensity, 0), 1)
        let scrimFactor = (1.0 - seeThrough * 0.65) * (0.45 + blur * 0.45)

        if activeColorScheme == .light {
            return LinearGradient(
                colors: [
                    Color.white.opacity(min(0.92, 0.16 + scrimFactor * 0.45)),
                    Color.white.opacity(min(0.96, 0.24 + scrimFactor * 0.55))
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            return LinearGradient(
                colors: [
                    Color.black.opacity(min(0.92, 0.20 + scrimFactor * 0.48)),
                    Color.black.opacity(min(0.96, 0.30 + scrimFactor * 0.58))
                ],
                startPoint: .top,
                endPoint: .bottom
            )
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
        ZStack(alignment: .center) {
            GeometryReader { geometry in
                let horizontalPadding: CGFloat = geometry.size.width < 375 ? 24 : 32
                let isCompact = geometry.size.height < 700
                let maxCardHeight = min(
                    geometry.size.height * (isCompact ? 0.34 : 0.40),
                    360
                )

                ZStack(alignment: .center) {
                    playerBackground
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .ignoresSafeArea()

                    VStack(spacing: 0) {
                        Capsule()
                            .fill(primaryForeground.opacity(0.28))
                            .frame(width: 36, height: 5)
                            .padding(.top, 14)
                            .padding(.bottom, 12)
                            .contentShape(Rectangle().size(width: 60, height: 30))
                            .onTapGesture {
                                guard showLyrics else { return }
                                withAnimation(.easeInOut(duration: 0.24)) {
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
                            .tint(primaryForeground)
                            .environment(\.colorScheme, activeColorScheme)
                            .animation(.easeInOut(duration: 0.16), value: np.isPlaying)
                            .scaleEffect(isCompact ? 0.94 : 1)
                            .padding(.bottom, isCompact ? 4 : 10)

                            SecondaryActionsRow(
                                showLyrics: $showLyrics,
                                showQueue: $showQueue,
                                isRepeatOn: $np.isRepeatOn
                            )
                            .foregroundStyle(secondaryForeground)
                            .tint(primaryForeground)
                            .environment(\.colorScheme, activeColorScheme)
                            .padding(.horizontal, horizontalPadding - 10)
                            .scaleEffect(isCompact ? 0.94 : 1)

                            Spacer(minLength: isCompact ? 6 : 12)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(primaryForeground)
        .tint(primaryForeground)
        .environment(\.colorScheme, activeColorScheme)
        .toolbar(.hidden, for: .tabBar)
        .ignoresSafeArea()
        .offset(y: collapseOffset)
        .animation(.easeInOut(duration: 0.24), value: collapseOffset)
        .animation(.easeInOut(duration: 0.24), value: showQueue)
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

    @ViewBuilder
    private var playerBackground: some View {
        if np.isVideoMode && np.hasVideo {
            Color.black
        } else {
            switch settings.playerBackgroundStyle {
            case .solid:
                activeColorScheme == .light ? Color.white : Color.black

            case .tinted:
                ZStack {
                    tintedBackgroundGradient
                    Circle()
                        .fill(accentSeedColor)
                        .frame(width: 420, height: 420)
                        .blur(radius: 120)
                        .opacity(activeColorScheme == .light ? 0.22 : 0.36)
                        .offset(y: -150)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .animation(.easeInOut(duration: 0.45), value: np.videoId)

            case .blur:
                let blurIntensity = min(max(settings.playerBlurIntensity, 0), 1)
                let transparentIntensity = min(max(settings.playerTransparentIntensity, 0), 1)
                ZStack {
                    Rectangle()
                        .fill(materialForBlurIntensity(blurIntensity))
                        .opacity(max(0.25, 1.0 - transparentIntensity * 0.55))
                    blurOverlay
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.25), value: blurIntensity)
                .animation(.easeInOut(duration: 0.25), value: transparentIntensity)
            }
        }
    }

    private func materialForBlurIntensity(_ intensity: Double) -> Material {
        switch intensity {
        case ..<0.34:
            return .ultraThinMaterial
        case ..<0.67:
            return .thinMaterial
        default:
            return .regularMaterial
        }
    }

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
        withAnimation(.easeInOut(duration: 0.24)) {
            artworkEntryOffset = 0
        }
    }

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

    private func preloadLyrics() {
        guard let id = np.videoId else { return }
        let upcoming = np.upcomingSongs(prefixLimit: 3).map(\.videoId)
        Task { await LyricsService.shared.preload(videoId: id, upcoming: upcoming) }
    }

    private var titleAndActionsRow: some View {
        HStack(alignment: .top, spacing: 12) {
            PlayerTitleBlock(
                title: np.title,
                artist: np.displayArtist,
                spacing: 4,
                titleFont: .title3.weight(.semibold),
                titleHeight: 28,
                titleColor: primaryForeground,
                artistColor: secondaryForeground,
                badge: effectiveAudioBadge,
                is256AAC: effectiveIs256AAC,
                isDownloaded: isCurrentSongDownloaded,
                showsBadge: isCurrentSongDownloaded || !isAudioBadgeHiddenByUser,
                resetKey: "\(np.videoId ?? "")-\(np.queueIndex)",
                onTitleTap: {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isAudioBadgeHiddenByUser.toggle()
                    }
                }
            )
            .foregroundStyle(primaryForeground)
            .tint(primaryForeground)
            .environment(\.colorScheme, activeColorScheme)
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            HStack(spacing: 8) {
                PlayerLikeButton(
                    isLiked: isLiked,
                    inactiveColor: primaryForeground
                ) {
                    guard let song = np.currentSong else { return }
                    Task { await likeStore.toggle(song: song) }
                }
                .foregroundStyle(primaryForeground)
                .tint(primaryForeground)
                .environment(\.colorScheme, activeColorScheme)

                if np.currentSong != nil {
                    PlayerOptionsButton(color: primaryForeground) {
                        showSongMenu = true
                    }
                    .foregroundStyle(primaryForeground)
                    .tint(primaryForeground)
                    .environment(\.colorScheme, activeColorScheme)
                }
            }
            .offset(y: -4)
        }
    }

    private var musicVideoContent: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.24)) {
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
        .animation(.easeOut(duration: 0.18), value: np.isVideoReady)
    }

    private func artworkCard(maxHeight: CGFloat, horizontalPadding: CGFloat) -> some View {
        ZStack {
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
        .shadow(
            color: Color.black.opacity(activeColorScheme == .light ? 0.18 : 0.42),
            radius: 22,
            x: 0,
            y: 12
        )
        .scaleEffect(np.isPlaying ? 1.0 : 0.78)
        .animation(.easeInOut(duration: 0.14), value: np.isPlaying)
        .offset(x: artworkEntryOffset)
        .gesture(artworkSwipe)
        .onTapGesture {
            guard np.hasVideo else { return }
            showQueue = true
            player.setVideoMode()
        }
        .padding(.horizontal, horizontalPadding)
    }

    private var artworkImage: some View {
        Group {
            if let uiImage = np.thumbnailUIImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
            } else {
                Rectangle()
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
                accentColor: primaryForeground,
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
            .foregroundStyle(primaryForeground)
            .tint(primaryForeground)
            .environment(\.colorScheme, activeColorScheme)

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

private extension Color {
    func blended(over base: Color) -> Color {
        let top = UIColor(self)
        let bottom = UIColor(base)

        var tr: CGFloat = 0, tg: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0

        guard top.getRed(&tr, green: &tg, blue: &tb, alpha: &ta),
              bottom.getRed(&br, green: &bg, blue: &bb, alpha: &ba) else {
            return base
        }

        let alpha = min(max(ta, 0), 1)
        let r = tr * alpha + br * (1 - alpha)
        let g = tg * alpha + bg * (1 - alpha)
        let b = tb * alpha + bb * (1 - alpha)
        return Color(red: Double(r), green: Double(g), blue: Double(b))
    }
}
