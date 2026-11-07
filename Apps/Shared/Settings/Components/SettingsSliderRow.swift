import SwiftUI

/// A value picked along a range, read out in words beside its title.
///
/// The slider moves a local draft and the stored value settles once it stops, so a synced
/// setting isn't written on every frame of a drag (and can't bounce back from another device
/// mid-drag). On iPhone the slider takes its own line under the title; on the Mac it sits in
/// the row, trailing, with its value beside it.
struct SettingsSliderRow: View {
    var title: LocalizedStringKey
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var minimumLabel: Text
    var maximumLabel: Text
    /// The value in words, for the row and for VoiceOver.
    var describe: (Double) -> String

    @State private var draft: Double?

    private var shown: Double { draft ?? value }

    var body: some View {
        #if os(macOS)
        LabeledContent {
            // No words at the ends: the value beside the slider says where it is, and the
            // row stays one line beside a long title.
            HStack(spacing: SettingsSpacing.row) {
                Slider(
                    value: Binding(get: { shown }, set: { draft = ($0 / step).rounded() * step }),
                    in: range
                ) {
                    Text(title)
                }
                .labelsHidden()
                .accessibilityValue(describe(shown))
                .frame(width: 160)
                Text(describe(shown))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 56, alignment: .trailing)
            }
        } label: {
            Text(title)
        }
        .settling(draft: $draft, into: $value)
        #else
        VStack(alignment: .leading, spacing: SettingsSpacing.standard) {
            LabeledContent(title) {
                Text(describe(shown))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: shown))
            }
            slider
                .labelsHidden()
        }
        .settling(draft: $draft, into: $value)
        #endif
    }

    private var slider: some View {
        // Continuous, rounded to the step as it moves: a stepped slider draws a tick for
        // every step, and sixty of them read as a dotted rule.
        Slider(
            value: Binding(get: { shown }, set: { draft = ($0 / step).rounded() * step }),
            in: range
        ) {
            Text(title)
        } minimumValueLabel: {
            minimumLabel.font(.footnote).foregroundStyle(.secondary)
        } maximumValueLabel: {
            maximumLabel.font(.footnote).foregroundStyle(.secondary)
        }
        .accessibilityValue(describe(shown))
    }
}

private extension View {
    /// Writes the draft into the stored value about 200 ms after it stops changing, or at
    /// once if the row goes away first, so a quick change before leaving the page still counts.
    func settling(draft: Binding<Double?>, into value: Binding<Double>) -> some View {
        task(id: draft.wrappedValue) {
            guard let settled = draft.wrappedValue else { return }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            value.wrappedValue = settled
            draft.wrappedValue = nil
        }
        .onDisappear {
            guard let settled = draft.wrappedValue else { return }
            value.wrappedValue = settled
            draft.wrappedValue = nil
        }
    }
}
