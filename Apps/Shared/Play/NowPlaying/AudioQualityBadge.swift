import SwiftUI
import TracksCore

/// What's playing, and how well, as Music shows Lossless between Now Playing's times: Apple
/// Music's Lossless, Hi-Res Lossless, Dolby Atmos or AAC, or what your own music is really
/// playing at, "MP3 · 320 kbps" when a server makes a smaller copy. Tapped, it says where the
/// song is coming from and why it's at this quality.
///
/// Nothing shows while the quality isn't known (a stream the server was asked to shrink, until
/// the player has heard it; Apple Music while a song loads), or when Show Audio Quality is off.
struct AudioQualityBadge: View {
    enum Style {
        /// On Now Playing's coloured field, tapped for its details.
        case stage
        /// On the Mac's player bar: the badge alone, its details in the full player, and
        /// under the pointer.
        case bar
    }

    let track: PlayerTrack
    var style = Style.stage

    /// Show Audio Quality, in Settings ▸ Play. On unless turned off.
    static let showsKey = "playShowsAudioQuality"

    @AppStorage(Self.showsKey) private var isShown = true
    @Environment(PlayerModel.self) private var player
    @Environment(YourMusic.self) private var music
    @State private var showsDetails = LaunchScene.opensQualityDetails

    var body: some View {
        if isShown, let quality {
            switch style {
            case .stage:
                Button {
                    showsDetails = true
                } label: {
                    QualityCapsule(label: quality.label, showsWaveform: quality.showsWaveform, onDark: true)
                        // A bigger target around a small capsule, short of the scrubber's
                        // track above it. It sits in an overlay, so the room it takes moves nothing.
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showsDetails) {
                    AudioQualityDetails(quality: quality)
                        .presentationCompactAdaptation(.popover)
                        // Clear glass over the stage let the title show through the words.
                        .presentationBackground(.thickMaterial)
                }
                .accessibilityLabel("Audio Quality")
                .accessibilityValue(Text(quality.spokenLabel))
                .accessibilityHint("Shows where the song is coming from, and why it plays at this quality.")
            case .bar:
                QualityCapsule(label: quality.label, showsWaveform: quality.showsWaveform, onDark: false)
                    .help(Text("\(quality.factsLine). \(quality.reasonLine)"))
                    .accessibilityLabel(Text(quality.spokenLabel))
            }
        }
    }

    private var quality: AudioQuality? {
        if let local = track.local {
            #if DEBUG
            if player.isDemo { return AudioQuality(music.demoPlayback(for: local)) }
            #endif
            return music.playbacks[track.id].flatMap(AudioQuality.init)
        }
        return Self.appleMusicQuality(of: track, in: player)
    }

    /// What an Apple Music song playing is at, as the player reports it.
    static func appleMusicQuality(of track: PlayerTrack, in player: PlayerModel) -> AudioQuality? {
        guard track.local == nil else { return nil }
        #if DEBUG
        // Most of Apple Music's catalog is in Lossless: the sample songs play as if in it.
        if player.isDemo { return AudioQuality(appleMusic: .lossless) }
        #endif
        // A song loading may still carry the last one's variant.
        guard !player.isDemo, player.status != .loading, track.song != nil else { return nil }
        return MusicKitPlayerEngine.playingVariant.map(AudioQuality.init(appleMusic:))
    }
}

/// The capsule itself: a quiet pill of small bold type, with the waveform for lossless, as
/// Music draws Lossless.
struct QualityCapsule: View {
    let label: String
    var showsWaveform = false
    /// On Now Playing's coloured field rather than the page.
    var onDark = false

    var body: some View {
        HStack(spacing: 4) {
            if showsWaveform {
                Image(systemName: "waveform")
                    .font(.caption2.weight(.bold))
                    .accessibilityHidden(true)
            }
            Text(label)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(onDark ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
        .background(onDark ? AnyShapeStyle(.white.opacity(0.14)) : AnyShapeStyle(Color(.tertiarySystemFill)), in: .capsule)
    }
}

/// What the badge opens to: the quality, where the song is coming from with its format in
/// full, and why it's at this quality.
struct AudioQualityDetails: View {
    let quality: AudioQuality

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(quality.label)
            } icon: {
                if quality.showsWaveform {
                    Image(systemName: "waveform")
                }
            }
            .labelStyle(QualityTitleLabelStyle(showsIcon: quality.showsWaveform))
            .font(.headline)
            Text(quality.factsLine)
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
            Text(quality.reasonLine)
                .font(.footnote)
                .foregroundStyle(Color.secondary)
                .padding(.top, 6)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: Self.width, alignment: .leading)
        .padding(16)
        // Opened from Now Playing's white-inked stage: the popover's own ink, not the stage's,
        // which `.primary` would only have taken the first level of.
        .foregroundStyle(Color.primary)
        .accessibilityElement(children: .combine)
    }

    #if os(macOS)
    private static let width: CGFloat = 260
    #else
    private static let width: CGFloat = 280
    #endif
}

/// The title's glyph close beside it, and no gap where a compressed song has none.
private struct QualityTitleLabelStyle: LabelStyle {
    let showsIcon: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            if showsIcon { configuration.icon }
            configuration.title
        }
    }
}

#if DEBUG
#Preview("Details") {
    VStack(spacing: 20) {
        AudioQualityDetails(quality: AudioQuality(appleMusic: .lossless))
        AudioQualityDetails(quality: AudioQuality(LocalPlayback(
            route: .stream(server: "Octo", network: .cellular, requestedBitRate: 320),
            original: AudioFormat(codec: "FLAC", sampleRate: 96_000, bitDepth: 24),
            actual: AudioFormat(codec: "MP3", sampleRate: 44_100, bitRate: 320)
        ))!)
    }
}
#endif
