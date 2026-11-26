//
//  PlayerComponents.swift
//  Nugget
//
//
//

import SwiftUI
import AVKit

private func playerInkColor(for colorScheme: ColorScheme) -> Color {
    colorScheme == .light ? .black : .white
}

// MARK: - ProgressBar
struct ProgressBar: View {
    @Binding var progress: Float
    let accentColor: Color
    let isPlaying: Bool
    let onEditingChanged: (Bool) -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var ink: Color { playerInkColor(for: colorScheme) }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let elapsedWidth = max(0, min(width, width * CGFloat(progress)))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(ink.opacity(0.16))
                    .frame(height: 6)

                Capsule()
                    .fill(ink.opacity(0.85))
                    .frame(width: elapsedWidth, height: 6)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onEditingChanged(true)
                        let loc = value.location.x
                        let percent = max(0, min(1, loc / width))
                        progress = Float(percent)
                    }
                    .onEnded { _ in
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 12)
    }
}

// MARK: - PlaybackControlsRow
struct PlayerPlayPauseButton: View {
    let isPlaying: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            ZStack {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 42, weight: .regular))
                    .foregroundStyle(playerInkColor(for: colorScheme))
                    .id(isPlaying)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
            .frame(width: 56, height: 56)
            .animation(.easeInOut(duration: 0.14), value: isPlaying)
        }
        .buttonStyle(.plain)
        .frame(width: 80, height: 80)
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }
}

struct PlaybackControlsRow: View {
    let isPlaying: Bool
    let hasPrevious: Bool
    let hasNext: Bool

    let onPrevious: () -> Void
    let onPlayPause: () -> Void
    let onNext: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var ink: Color { playerInkColor(for: colorScheme) }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onPrevious) {
                Image(systemName: "backward.fill")
                    .font(.title)
                    .foregroundStyle(ink)
            }
            .disabled(!hasPrevious)
            .opacity(hasPrevious ? 1 : 0.3)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Previous")

            PlayerPlayPauseButton(isPlaying: isPlaying, action: onPlayPause)
                .frame(maxWidth: .infinity)

            Button(action: onNext) {
                Image(systemName: "forward.fill")
                    .font(.title)
                    .foregroundStyle(ink)
            }
            .disabled(!hasNext)
            .opacity(hasNext ? 1 : 0.3)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Next")
        }
        .padding(.horizontal, 24)
    }
}

struct PlayerTransportAirPlayFooter: View {
    let isPlaying: Bool
    let hasPrevious: Bool
    let hasNext: Bool
    let onPrevious: () -> Void
    let onPlayPause: () -> Void
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PlaybackControlsRow(
                isPlaying: isPlaying,
                hasPrevious: hasPrevious,
                hasNext: hasNext,
                onPrevious: onPrevious,
                onPlayPause: onPlayPause,
                onNext: onNext
            )
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isPlaying)

            HStack {
                Spacer()
                PlayerAirPlayControl()
                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 16)
    }
}

// MARK: - SecondaryActionsRow (Lyrics left, AirPlay center, Queue + Repeat right)
struct SecondaryActionsRow: View {
    @Binding var showLyrics: Bool
    @Binding var showQueue: Bool
    @Binding var isRepeatOn: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var ink: Color { playerInkColor(for: colorScheme) }

    init(
        showLyrics: Binding<Bool> = .constant(false),
        showQueue: Binding<Bool>,
        isRepeatOn: Binding<Bool>
    ) {
        self._showLyrics = showLyrics
        self._showQueue = showQueue
        self._isRepeatOn = isRepeatOn
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left: Lyrics toggle
            Button {
                withAnimation(.easeInOut(duration: 0.3)) {
                    showLyrics.toggle()
                }
            } label: {
                Image(systemName: showLyrics ? "quote.bubble.fill" : "quote.bubble")
                    .font(.title3)
                    .foregroundStyle(showLyrics ? ink : ink.opacity(0.7))
                    .padding(10)
                    .background(showLyrics ? Circle().fill(ink.opacity(0.15)) : Circle().fill(.clear))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Lyrics")

            // Center: AirPlay / Audio output
            PlayerAirPlayControl()
                .frame(maxWidth: .infinity)

            // Right: Queue + Repeat stacked like Apple Music
            ZStack(alignment: .topTrailing) {
                Button {
                    showQueue.toggle()
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.title3)
                        .foregroundStyle(showQueue ? ink : ink.opacity(0.7))
                        .padding(10)
                        .background(showQueue ? Circle().fill(ink.opacity(0.15)) : Circle().fill(.clear))
                }
                .accessibilityLabel("Queue")

                if !showQueue {
                    Button {
                        isRepeatOn.toggle()
                    } label: {
                        Image(systemName: isRepeatOn ? "repeat.1" : "repeat")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(isRepeatOn ? ink : ink.opacity(0.7))
                            .padding(4)
                    }
                    .offset(x: 2, y: -2)
                    .accessibilityLabel(isRepeatOn ? "Repeat one" : "Repeat all")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 16)
    }
}

struct PlayerAirPlayControl: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button {} label: {
            Image(systemName: "airplayaudio")
                .font(.title3)
                .foregroundStyle(playerInkColor(for: colorScheme).opacity(0.7))
                .padding(10)
        }
        .overlay(AirPlayButton())
        .accessibilityLabel("AirPlay")
    }
}

// MARK: - AirPlayButton
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: UIViewRepresentableContext<Self>) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = UIColor.clear
        picker.activeTintColor = UIColor.clear
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: UIViewRepresentableContext<Self>) {}
}
