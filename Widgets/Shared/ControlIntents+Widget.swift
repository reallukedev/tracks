import AppIntents

// The extension's half of ControlIntents.swift. These intents only run in the app
// (`allowedExecutionTargets`), so this only keeps the extension, which has no app model,
// building. If the system ever ran one here, it says so rather than doing nothing.

private let runsInApp = PlayIntentProblem("Open Tracks, then try again.")

extension StartPlayChoiceIntent {
    @MainActor static func start(_ choice: PlayChoice) async throws { throw runsInApp }
}

extension SaveRadioSongControlIntent {
    @MainActor static func save() async throws -> String { throw runsInApp }
}

extension IdentifySongIntent {
    @MainActor static func open() async throws { throw runsInApp }
}

private struct PlayIntentProblem: Error, CustomLocalizedStringResourceConvertible {
    let localizedStringResource: LocalizedStringResource

    init(_ message: LocalizedStringResource) {
        localizedStringResource = message
    }
}
