import SwiftUI
import TracksCore
#if os(iOS)
import UIKit
#endif

/// Listening for the song playing nearby, then what it is: Play, and where it sits in your
/// history. A sheet on iPhone and a popover from the toolbar on the Mac.
struct IdentifySongView: View {
    @Environment(AppModel.self) private var model
    @Environment(PlayerModel.self) private var player
    @Environment(\.openPlayRoute) private var openRoute
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @State private var identifier = SongIdentifier()
    /// Bumped by Try Again, so listening runs again as the view's own task.
    @State private var attempt = 0

    var body: some View {
        IdentifyPhaseView(
            phase: identifier.phase,
            play: { play($0) },
            showInHistory: { showInHistory($0) },
            searchAppleMusic: searchAction,
            tryAgain: { attempt += 1 },
            openSettings: { openMicrophoneSettings() }
        )
        .task(id: attempt) {
            await identifier.listen(history: model.library.history, isDemo: model.isShowingSampleData)
        }
        .onChange(of: identifier.phase) { _, phase in announce(phase) }
    }

    /// Apple Music can't be searched with sample data.
    private var searchAction: ((IdentifiedSong) -> Void)? {
        guard !model.isShowingSampleData else { return nil }
        return { searchAppleMusic($0) }
    }

    private func announce(_ phase: SongIdentifier.Phase) {
        guard case .found(let song) = phase else { return }
        AccessibilityNotification.Announcement(String(localized: "\(song.title) by \(song.artistName)")).post()
    }

    private func play(_ song: IdentifiedSong) {
        guard player.canPlay(songID: song.songID) else { return }
        let cover: String? = if case .url(let url, _) = song.cover { url } else { nil }
        player.play(
            .history([HistorySong(songID: song.songID, title: song.title, artistName: song.artistName, artworkURL: cover)]),
            from: .songs(String(localized: "Search"))
        )
        dismiss()
    }

    private func showInHistory(_ song: IdentifiedSong) {
        dismiss()
        openRoute(.stats(.song(song.songIdentity)))
    }

    private func searchAppleMusic(_ song: IdentifiedSong) {
        dismiss()
        model.beginSearch(in: .appleMusic, for: "\(song.title) \(song.artistName)")
    }

    private func openMicrophoneSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        #else
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { openURL(url) }
        #endif
    }
}

/// One phase of identifying, drawn: separate from listening, so each can be previewed.
struct IdentifyPhaseView: View {
    let phase: SongIdentifier.Phase
    var play: (IdentifiedSong) -> Void = { _ in }
    var showInHistory: (IdentifiedSong) -> Void = { _ in }
    /// Nil where Apple Music can't be searched, with sample data.
    var searchAppleMusic: ((IdentifiedSong) -> Void)?
    var tryAgain: () -> Void = {}
    var openSettings: () -> Void = {}

    @Environment(PlayerModel.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            switch phase {
            case .listening:
                listening
            case .found(let song):
                found(song)
            case .noMatch:
                problem(
                    "No Match",
                    symbol: "shazam.logo",
                    message: "Tracks couldn’t name this song. Try again closer to the music, while it’s playing.",
                    action: ("Try Again", tryAgain)
                )
            case .microphoneDenied:
                problem(
                    "Microphone Access Is Off",
                    symbol: "mic.slash",
                    message: "To name a song playing near you, allow Tracks to use the microphone.",
                    action: (Self.settingsTitle, openSettings)
                )
            case .offline:
                problem(
                    "You’re Offline",
                    symbol: "wifi.slash",
                    message: "Naming a song needs an internet connection.",
                    action: ("Try Again", tryAgain)
                )
            case .failed:
                problem(
                    "Couldn’t Listen",
                    symbol: "exclamationmark.triangle",
                    message: "Something went wrong. Try again in a moment.",
                    action: ("Try Again", tryAgain)
                )
            }
        }
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .snappy, value: phase)
        #if os(iOS)
        .sensoryFeedback(.success, trigger: isFound) { _, now in now }
        #endif
    }

    private var isFound: Bool {
        if case .found = phase { true } else { false }
    }

    private var listening: some View {
        VStack(spacing: 18) {
            Image(systemName: "shazam.logo.fill")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
                .symbolEffect(.breathe, isActive: !reduceMotion)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text("Listening…")
                    .font(.title3.bold())
                Text(Self.listeningHint)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.vertical, 24)
        .accessibilityElement(children: .combine)
    }

    private func found(_ song: IdentifiedSong) -> some View {
        VStack(spacing: 16) {
            CoverImage(cover: song.cover, size: dynamicTypeSize.isAccessibilitySize ? 112 : 168)
                .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
                .accessibilityHidden(true)
            VStack(spacing: 3) {
                Text(song.title)
                    .font(.title3.bold())
                    .lineLimit(3)
                if !song.artistName.isEmpty {
                    Text(song.artistName)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let heard = Self.heard(song) {
                    Text(heard)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { actions(song) }
                VStack(spacing: 10) { actions(song) }
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func actions(_ song: IdentifiedSong) -> some View {
        if player.canPlay(songID: song.songID) {
            Button("Play", systemImage: "play.fill") { play(song) }
                .buttonStyle(.borderedProminent)
        }
        if song.lastPlay != nil {
            Button("Show in History", systemImage: "clock.arrow.circlepath") { showInHistory(song) }
                .buttonStyle(.bordered)
        } else if let searchAppleMusic {
            Button("Search Apple Music", systemImage: "magnifyingglass") { searchAppleMusic(song) }
                .buttonStyle(.bordered)
        }
    }

    private func problem(
        _ title: LocalizedStringKey,
        symbol: String,
        message: LocalizedStringKey,
        action: (title: LocalizedStringKey, run: () -> Void)
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            Button(action.title, action: action.run)
                .buttonStyle(.bordered)
        }
    }

    /// Where and when you last heard it, the moment Tracks is for: "You heard it on KEXP
    /// yesterday".
    static func heard(_ song: IdentifiedSong, now: Date = .now) -> String? {
        guard let play = song.lastPlay else { return nil }
        let when = play.capturedAt.formatted(.relative(presentation: .named, unitsStyle: .wide))
        if play.kind == .radio, let station = play.stationName, !station.isEmpty {
            return String(localized: "You heard it on \(station) \(when).")
        }
        return String(localized: "You last played it \(when).")
    }

    #if os(iOS)
    private static let listeningHint: LocalizedStringKey = "Hold your iPhone near the music."
    private static let settingsTitle: LocalizedStringKey = "Open Settings"
    #else
    private static let listeningHint: LocalizedStringKey = "Keep your Mac near the music."
    private static let settingsTitle: LocalizedStringKey = "Open System Settings"
    #endif
}

#if DEBUG
private extension IdentifiedSong {
    static func preview(title: String, artist: String, heardOn station: String?) -> IdentifiedSong {
        let play = CaptureStat(
            songKey: title, songID: "1", title: title, artistName: artist,
            capturedAt: .now.addingTimeInterval(-2 * 86_400), stationName: station,
            kind: station == nil ? .onDemand : .radio
        )
        return IdentifiedSong(
            title: title, artistName: artist, cover: .url(nil, seed: title), songID: "1",
            history: ListeningHistory([play])
        )
    }
}

#Preview("Identify: every phase") {
    ScrollView {
        VStack(spacing: 40) {
            IdentifyPhaseView(phase: .listening)
            IdentifyPhaseView(phase: .found(.preview(title: "Driftwood", artist: "Mara Solís", heardOn: "Late Night Jazz")))
            IdentifyPhaseView(phase: .found(.preview(
                title: "Everything I Meant to Say on the Drive Home, Part Two (Live from the Echo Park Rooftop)",
                artist: "The Velvet Hours, Juniper Lane and Wren & Ivy",
                heardOn: nil
            )))
            IdentifyPhaseView(phase: .noMatch)
            IdentifyPhaseView(phase: .microphoneDenied)
            IdentifyPhaseView(phase: .offline)
        }
        .padding(20)
    }
    .frame(width: 340)
    .environment(PlayerModel(engine: DemoPlayerEngine { [] }, isDemo: true))
}
#endif
