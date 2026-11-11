import AppIntents

// The actions behind the controls in Control Center, on the Lock Screen, on the Action
// button and in the Mac's menu bar.
//
// The widget extension compiles this file so its controls can name these intents, but each
// one runs in the app (`allowedExecutionTargets`), which has the player and the capture
// stack. Their work is in ControlIntents+App.swift; the extension's half, in
// ControlIntents+Widget.swift, is never run. They're hidden from Shortcuts, which already
// lists the app's own versions (Play in Tracks, Save Current Radio Song).

/// Which of the Play choices a Play in Tracks control starts.
struct PlayInTracksControlConfiguration: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Play in Tracks"
    static let isDiscoverable = false

    @Parameter(title: "Music", default: .station)
    var choice: PlayChoice
}

/// Starts a mix, a mood, Tracks Radio or live radio, without opening Tracks.
struct StartPlayChoiceIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play in Tracks"
    static let isDiscoverable = false
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Music", default: .station)
    var choice: PlayChoice

    init() {}

    init(choice: PlayChoice) {
        self.choice = choice
    }

    func perform() async throws -> some IntentResult {
        try await Self.start(choice)
        return .result()
    }
}

/// Saves the radio song playing now, as Save Current Radio Song does, from a control.
struct SaveRadioSongControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Save Radio Song"
    static let isDiscoverable = false
    static let supportedModes: IntentModes = .background
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: try await Self.save()))
    }
}

/// Opens Search listening for the song playing nearby.
struct IdentifySongIntent: AppIntent {
    static let title: LocalizedStringResource = "Identify Song"
    static let description = IntentDescription(
        "Opens Tracks listening for the song playing nearby, and finds it in your history.",
        categoryName: "Search"
    )
    static let supportedModes: IntentModes = .foreground(.immediate)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    func perform() async throws -> some IntentResult {
        try await Self.open()
        return .result()
    }
}
