import SwiftUI

/// A small labelled figure along the bottom of a card, like "Daily Average".
struct StatFootnote: View {
    let title: LocalizedStringKey
    let value: Text
    /// The colour of the bars this figure is about, as a chart's key shows it.
    var swatch: AnyShapeStyle?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                if let swatch {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(swatch)
                        .frame(width: 8, height: 8)
                }
                Text(title)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            value
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .accessibilityElement(children: .combine)
    }
}
