import SwiftUI

/// The filled, rounded well Settings puts before a row. Scales with Dynamic Type.
struct SettingsIconTile: View {
    var systemImage: String
    var color: Color
    /// Side at the default text size: 28 in rows, 64 (iPhone) or 40 (Mac) in a hero.
    var baseSide: CGFloat = 28

    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    /// A hero's tile grows less than a row's: at the largest sizes it would otherwise fill
    /// the screen before the words it introduces.
    private var side: CGFloat { baseSide * min(scale, baseSide > 28 ? 1.35 : 2) }

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: side * 0.5, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(color.gradient, in: .rect(cornerRadius: side * 0.28, style: .continuous))
            // The row's words carry the meaning; the tile is decoration.
            .accessibilityHidden(true)
    }
}
