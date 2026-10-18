import AppIntents
import TracksCore
import TracksMusic

/// Plays back today's captures.
///
/// Runs in the foreground so playback starts from the app. Run in the background (from the
/// widget, say), its process can be terminated as soon as the intent returns.
struct PlayBackTodayIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Back Today"
    static let description = IntentDescription(
        "Plays the songs Tracks captured today, so they count as real plays in your listening history.",
        categoryName: "Playback"
    )

    static let supportedModes: IntentModes = .foreground

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // The app's own controller (see PlayInTracksIntent.swift), which lives on to mark each
        // song played back as it ends. The widgets' half is in PlayBackButton.swift.
        let controller = try Self.playbackController()
        await controller.playBackToday()

        if let error = controller.lastError {
            return .result(dialog: IntentDialog(stringLiteral: error))
        }
        return .result(dialog: "^[Playing \(controller.queuedCount) song](inflect: true).")
    }
}
