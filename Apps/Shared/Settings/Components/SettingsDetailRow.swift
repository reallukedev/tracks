import SwiftUI

/// A name with a line under it and a control after, the control centered on the whole
/// text block. `Toggle` and `LabeledContent` hang a two-line label from its first line,
/// which leaves the control riding high beside the title.
struct SettingsDetailRow<Trailing: View>: View {
    var title: Text
    var detail: Text
    var trailing: Trailing

    init(title: Text, detail: Text, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: SettingsSpacing.row) {
            VStack(alignment: .leading, spacing: 2) {
                title
                detail
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.vertical, 2)
    }
}

/// An on/off setting. On the Mac, a detail row whose line says what the current position
/// means; on iPhone, a plain switch, with the explanation in its group's footer as iOS
/// Settings does it.
struct SettingsSwitch: View {
    var title: LocalizedStringKey
    var detail: Text
    @Binding var isOn: Bool

    init(_ title: LocalizedStringKey, detail: Text, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self._isOn = isOn
    }

    var body: some View {
        #if os(macOS)
        SettingsDetailRow(title: Text(title), detail: detail) {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        #else
        Toggle(title, isOn: $isOn)
        #endif
    }
}
