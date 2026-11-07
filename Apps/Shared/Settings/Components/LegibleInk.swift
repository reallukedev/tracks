import SwiftUI
import TracksCore

/// A tint made readable as text: 4.5:1, or 7:1 with Increase Contrast. System orange and
/// green are made for fills; as text on a grouped background they mostly fail contrast.
struct LegibleInk: ShapeStyle {
    var tint: Color

    func resolve(in environment: EnvironmentValues) -> Color {
        let isDark = environment.colorScheme == .dark
        let target: Float = environment.colorSchemeContrast == .increased ? 7 : 4.5
        // The hardest common background: grouped gray in light, the cell in dark.
        let surface = isDark
            ? Color.Resolved(red: 0.110, green: 0.110, blue: 0.118)
            : Color.Resolved(red: 0.949, green: 0.949, blue: 0.969)
        let destination = isDark
            ? Color.Resolved(red: 1, green: 1, blue: 1)
            : Color.Resolved(red: 0, green: 0, blue: 0)
        let start = tint.resolve(in: environment)
        var candidate = start
        var amount: Float = 0
        while candidate.contrast(against: surface) < target && amount < 1 {
            amount = min(1, amount + 0.03)
            candidate = start.mixed(with: destination, by: amount)
        }
        return Color(candidate)
    }
}

extension ShapeStyle where Self == LegibleInk {
    /// Colored text that stays readable. Every orange "needs you" and red failure line in
    /// Settings goes through this, never a bare `.foregroundStyle(.orange)`.
    static func ink(_ tint: Color) -> LegibleInk { LegibleInk(tint: tint) }
}

nonisolated extension Color.Resolved {
    func mixed(with other: Color.Resolved, by amount: Float) -> Color.Resolved {
        Color.Resolved(
            red: red + (other.red - red) * amount,
            green: green + (other.green - green) * amount,
            blue: blue + (other.blue - blue) * amount,
            opacity: opacity
        )
    }

    var relativeLuminance: Float {
        0.2126 * linearRed + 0.7152 * linearGreen + 0.0722 * linearBlue
    }

    func contrast(against other: Color.Resolved) -> Float {
        let a = relativeLuminance, b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

extension SettingsTone {
    /// The status line in this tone: plain grey, orange ink, or red ink.
    func apply(to text: Text) -> Text {
        switch self {
        case .plain: text
        case .attention: text.foregroundStyle(.ink(.orange))
        case .failure: text.foregroundStyle(.ink(.red))
        }
    }
}
