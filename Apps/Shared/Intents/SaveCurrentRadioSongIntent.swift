import AppIntents
import TracksCore

/// Saves whatever radio song is playing right now.
///
/// iOS suspends the app soon after it leaves the foreground and there's no supported way to
/// observe the system player while suspended, so with the app closed this intent is the only
/// way to capture. The Action Button, Back Tap and Control Centre all invoke it.
struct SaveCurrentRadioSongIntent: AppIntent {
    static let title: LocalizedStringResource = "Save Current Radio Song"
    static let description = IntentDescription(
        "Adds the radio song playing right now to your Heard on Radio playlist.",
        categoryName: "Capture"
    )

    /// Runs without bringing the app forward.
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Created before capturing so the capture counts as a change.
        let widgets = WidgetRefresher.shared
        // Paused history keeps nothing, and says so rather than that nothing is playing.
        guard !CaptureService.isHistoryPaused else {
            return .result(dialog: "History is paused. Resume it in Tracks to save songs.")
        }
        // The app's own, when it's running, so the play is scrobbled and written once.
        let service = try CaptureService.shared()
        let decision = await service.captureCurrentSong()
        // Reload now, since the process is suspended soon after a background intent returns.
        widgets?.reloadIfChanged()

        switch decision {
        case .capture:
            guard let capture = service.lastCapture else {
                return .result(dialog: "Saved.")
            }
            return .result(dialog: "Saved \(capture.title) by \(capture.artistName).")

        case .ignore(let reason):
            return .result(dialog: IntentDialog(stringLiteral: Self.explain(reason)))
        }
    }

    /// A sentence for each reason a capture was rejected, so the shortcut never just does
    /// nothing.
    static func explain(_ reason: CaptureDecision.Reason) -> String {
        switch reason {
        case .notPlaying:
            "Nothing is playing right now."
        case .onDemand:
            "That song is playing on demand, so Apple Music already logs it."
        case .duplicate:
            "That one's already saved."
        case .stationAnnouncement(let name):
            "\(name) is still starting up. Try again once a song is playing."
        case .excludedStation(let name):
            "\(name) is excluded in Settings."
        case .unidentifiable:
            "Couldn't tell what's playing."
        case .tooShort(_, let needs):
            // Only reachable if the capture stops being forced.
            "That's only just started. It counts after ^[\(Int(needs)) second](inflect: true)."
        }
    }
}

/// Exposes the intent to Spotlight and Siri with spoken phrases.
struct TracksShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SaveCurrentRadioSongIntent(),
            phrases: [
                "Save this song with \(.applicationName)",
                "Save this radio song with \(.applicationName)",
                "\(.applicationName) save this track",
            ],
            shortTitle: "Save Radio Song",
            systemImageName: "radio"
        )
        // Play's: "Play music in Tracks" and the rest. See PlayInTracksIntent. Each
        // choice by name ("Play Discover in Tracks") comes from the last one's parameter, so
        // the fixed phrases don't repeat those.
        AppShortcut(
            intent: PlayInTracksIntent(choice: .station),
            phrases: [
                "Play music in \(.applicationName)",
                "Play \(.applicationName)",
                "Play \(.applicationName) Radio",
                "Play my station in \(.applicationName)",
            ],
            shortTitle: "Tracks Radio",
            systemImageName: "dot.radiowaves.left.and.right"
        )
        AppShortcut(
            intent: PlayInTracksIntent(choice: .forYou),
            phrases: [
                "Play something I like in \(.applicationName)",
            ],
            shortTitle: "My Mix",
            systemImageName: "sun.max"
        )
        AppShortcut(
            intent: PlayInTracksIntent(choice: .discover),
            phrases: [
                "Play something new in \(.applicationName)",
            ],
            shortTitle: "Discover",
            systemImageName: "binoculars"
        )
        AppShortcut(
            intent: SearchInTracksIntent(),
            phrases: [
                "Search \(.applicationName)",
                "Search in \(.applicationName)",
            ],
            shortTitle: "Search",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: PlayInTracksIntent(),
            phrases: [
                "Play \(\.$choice) in \(.applicationName)",
                "Play \(\.$choice) on \(.applicationName)",
            ],
            shortTitle: "Play a Mix",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: PlayMusicIntent(),
            phrases: [
                "Play a song in \(.applicationName)",
                "Play an album in \(.applicationName)",
                "Play an artist in \(.applicationName)",
                "Play a playlist in \(.applicationName)",
                "Find something to play in \(.applicationName)",
            ],
            shortTitle: "Play Music",
            systemImageName: "music.note"
        )
        AppShortcut(
            intent: SwitchMusicSourceIntent(),
            phrases: [
                "Switch \(.applicationName) to \(\.$source)",
                "Play from \(\.$source) in \(.applicationName)",
                "Use \(\.$source) in \(.applicationName)",
                "Switch music source in \(.applicationName)",
            ],
            shortTitle: "Switch Source",
            systemImageName: "arrow.left.arrow.right"
        )
        AppShortcut(
            intent: PlayOnDeviceIntent(),
            phrases: [
                "Play on \(\.$device) with \(.applicationName)",
                "Move the music to \(\.$device) with \(.applicationName)",
            ],
            shortTitle: "Play on Device",
            systemImageName: "laptopcomputer.and.iphone"
        )
        AppShortcut(
            intent: PlayHereIntent(),
            phrases: [
                "Bring the music here with \(.applicationName)",
                "Play it here with \(.applicationName)",
            ],
            shortTitle: "Bring Music Here",
            systemImageName: "arrow.down.forward.and.arrow.up.backward"
        )
    }
}
