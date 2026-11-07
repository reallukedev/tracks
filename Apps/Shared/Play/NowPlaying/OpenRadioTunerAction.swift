import SwiftUI

/// Opens Tracks Radio's tuning from inside a player whose own look (a dark stage, white type)
/// mustn't reach the sheet: the player presents it from outside that look, and what's inside
/// only asks.
struct OpenRadioTunerAction: Equatable {
    let run: @MainActor () -> Void

    /// Every one opens the same sheet, so a player making a new one as it redraws doesn't
    /// redraw everything that reads it.
    static func == (lhs: Self, rhs: Self) -> Bool { true }

    @MainActor
    func callAsFunction() {
        run()
    }
}

extension EnvironmentValues {
    /// Nil where nothing around presents the tuner.
    @Entry var openRadioTuner: OpenRadioTunerAction?
}
