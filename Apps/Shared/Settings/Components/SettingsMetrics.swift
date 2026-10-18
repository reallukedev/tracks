import SwiftUI

/// Spacing for Settings, named for where it goes.
enum SettingsSpacing {
    /// Between a title and its detail, a glyph and its text.
    static let tight: CGFloat = 4
    /// Inside a row.
    static let standard: CGFloat = 8
    /// Between a tile and its text.
    static let row: CGFloat = 12
}

/// Named for what moves, never for a duration. Every one is under 0.35 s.
enum SettingsMotion {
    /// Rows and sections arriving or leaving as a switch turns something on.
    static let row: Animation = .smooth(duration: 0.28)
    /// A number rolling to a new value, with `.contentTransition(.numericText())`.
    static let value: Animation = .snappy(duration: 0.2)
    /// Opacity only, for Reduce Motion and for footers that change their words.
    static let fade: Animation = .easeOut(duration: 0.22)

    /// Rows moving, or only fading under Reduce Motion.
    static func row(reduceMotion: Bool) -> Animation {
        reduceMotion ? fade : row
    }
}
