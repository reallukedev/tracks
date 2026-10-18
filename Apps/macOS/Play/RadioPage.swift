import SwiftUI
import TracksCore

/// Radio: your own station first, on a field of its colour, then Apple Music's live stations,
/// then the moods.
struct RadioPage: View {
    @Environment(PlayFeed.self) private var feed
    @Environment(AppModel.self) private var model
    @AppStorage(PlayPreferences.tracksRadioKey) private var isRadioOn = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PlayMetrics.sectionSpacing) {
                if isRadioOn {
                    TracksRadioStage()
                } else {
                    radioOff
                }
                if !feed.liveStations.isEmpty {
                    Shelf(title: String(localized: "Live Radio"), items: feed.liveStations) { item in
                        FeedTile(item: item)
                    }
                } else if feed.appleMusicState == .loading {
                    LoadingRows(count: 2)
                        .padding(.horizontal, PlayMetrics.margin)
                }
                MoodShelf()
            }
            .padding(.top, 20)
            .padding(.bottom, 32)
        }
        .navigationTitle("Radio")
        .task(id: model.musicAuthorization) { await feed.loadAppleMusic() }
    }

    /// Tracks Radio hidden in Settings: said so where it would be, with the way back.
    private var radioOff: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tracks Radio Is Off")
                .font(.title3.bold())
            Text("Your own station plays everything you love and new finds like it, picked as it plays.")
                .foregroundStyle(.secondary)
            Button("Turn On Tracks Radio") { isRadioOn = true }
                .buttonStyle(.bordered)
                .padding(.top, 4)
        }
        .padding(.horizontal, PlayMetrics.margin)
    }
}

/// Tracks Radio across the top of Radio: its artwork, what it's tuned to, and Play and Tune, on
/// a field of the station's own red.
private struct TracksRadioStage: View {
    @Environment(PlayerModel.self) private var player
    @AppStorage(PlayPreferences.radioTuningKey) private var storedTuning = ""
    @State private var showsTuner = false

    var body: some View {
        let isOn = player.isPlayingTracksRadio
        let tuning = RadioTuning(stored: storedTuning)
        HStack(alignment: .center, spacing: 28) {
            Button {
                if isOn { player.togglePlayPause() } else { player.playTracksRadio() }
            } label: {
                TracksRadioArt(side: 200, isLive: isOn && player.isPlaying, isDriving: player.isRadioDriving)
            }
            .buttonStyle(CoverLiftButtonStyle())
            .help(isOn && player.isPlaying ? "Pause Tracks Radio" : isOn ? "Resume Tracks Radio" : "Play Tracks Radio")
            .accessibilityLabel("Tracks Radio")

            VStack(alignment: .leading, spacing: 6) {
                Text("Your Station")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
                Text("Tracks Radio")
                    .font(.system(size: 30, weight: .bold))
                Text(tuning.summary)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                onAir(isOn: isOn)
                    .padding(.top, 8)
                HStack(spacing: 10) {
                    Button {
                        if isOn { player.togglePlayPause() } else { player.playTracksRadio() }
                    } label: {
                        Label(isOn && player.isPlaying ? "Pause" : isOn ? "Resume" : "Play", systemImage: isOn && player.isPlaying ? "pause.fill" : "play.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.stagePrimary(tint: TracksRadioArt.color))
                    Button("Tune…", systemImage: "slider.horizontal.3") { showsTuner = true }
                        .buttonStyle(.stageSecondary)
                        .help("How adventurous it is, the genres it leans into, and old favorites")
                }
                .padding(.top, 12)
            }
            .environment(\.colorScheme, .dark)
            .foregroundStyle(.white)
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .fill(TracksRadioArt.color.mix(with: .black, by: 0.35).gradient)
        }
        .padding(.horizontal, PlayMetrics.margin)
        .contextMenu {
            Button(isOn && player.isPlaying ? "Pause" : isOn ? "Resume" : "Play Tracks Radio", systemImage: isOn && player.isPlaying ? "pause" : "play") {
                if isOn { player.togglePlayPause() } else { player.playTracksRadio() }
            }
            Button("Tune Tracks Radio…", systemImage: "slider.horizontal.3") { showsTuner = true }
        }
        .sheet(isPresented: $showsTuner) { RadioTunerSheet() }
    }

    /// What's on it now, while it plays: the song, and that what's next is being picked. Before
    /// then, what it does, in a line.
    @ViewBuilder
    private func onAir(isOn: Bool) -> some View {
        if isOn, let track = player.current {
            HStack(spacing: 10) {
                CoverImage(cover: track.cover, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        PlayingWaveform(isActive: player.isPlaying, color: .secondary)
                        Text("On Air")
                            .textCase(.uppercase)
                    }
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    Text("\(track.title) · \(track.artistName)")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 6)
            .padding(.leading, 6)
            .padding(.trailing, 14)
            .background(.white.opacity(0.12), in: .capsule)
            .transition(.opacity)
            .id(track.id)
        } else {
            Text("Picked one song at a time as it plays. What you skip steers what comes next.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440, alignment: .leading)
        }
    }
}

/// The station's cover as a button: it lifts toward the pointer, and gives a little under a
/// click, as Music's covers do.
private struct CoverLiftButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        let isLifted = isHovering && !reduceMotion
        configuration.label
            .shadow(color: .black.opacity(isLifted ? 0.38 : 0.3), radius: isLifted ? 24 : 18, y: isLifted ? 14 : 10)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : isLifted ? 1.02 : 1)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.13), value: isHovering)
            .animation(.snappy(duration: 0.14), value: configuration.isPressed)
    }
}
