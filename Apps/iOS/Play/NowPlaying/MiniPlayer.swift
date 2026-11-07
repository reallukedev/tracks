import SwiftUI
import TracksCore

/// The song playing, above the tab bar on every tab, as Music's mini player is. Tapping it
/// opens Now Playing.
struct MiniPlayer: View {
    let open: () -> Void
    @Environment(PlayerModel.self) private var player
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @State private var nextTaps = 0
    @State private var playTaps = 0

    var body: some View {
        if let track = player.current {
            HStack(spacing: 10) {
                Button(action: open) {
                    HStack(spacing: 10) {
                        CoverImage(cover: track.cover, size: isInline ? 26 : 32)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(track.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            if !isInline {
                                Text(track.artistName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("\(track.title), \(track.artistName)"))
                .accessibilityHint("Opens Now Playing")

                Button {
                    playTaps += 1
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .contentTransition(.symbolEffect(.replace.magic(fallback: .replace.downUp)))
                }
                .buttonStyle(PlayerButtonStyle(diameter: 38, highlight: .primary))
                .overlay {
                    // Asked to play, and the song's still coming: a server finding it, or the
                    // first seconds arriving.
                    if player.isPlaying, player.status == .loading {
                        TurningRing(diameter: 34, lineWidth: 2)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: player.status == .loading)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                .accessibilityValue(player.isPlaying && player.status == .loading ? Text("Loading") : Text(""))

                if !isInline {
                    Button {
                        nextTaps += 1
                        player.skipToNext()
                    } label: {
                        SkipArrows(direction: .forward, height: 15, trigger: nextTaps)
                    }
                    .buttonStyle(PlayerButtonStyle(diameter: 38, highlight: .primary))
                    .accessibilityLabel("Next")
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            // The bar's height is the system's; bigger type would only be cut off.
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .sensoryFeedback(.impact(weight: .medium, intensity: 0.8), trigger: playTaps)
            .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: nextTaps)
        }
    }

    private var isInline: Bool { placement == .inline }
}
