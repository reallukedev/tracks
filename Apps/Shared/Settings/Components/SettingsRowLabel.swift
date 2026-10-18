import SwiftUI

/// A root row that leads to a page: a tile, a name, and where it stands at the trailing edge.
struct SettingsRowLabel: View {
    var title: LocalizedStringKey
    var systemImage: String
    var tint: Color
    var value: String?

    var body: some View {
        LabeledContent {
            if let value {
                Text(value)
                    .contentTransition(.opacity)
            }
        } label: {
            Label {
                Text(title)
            } icon: {
                SettingsIconTile(systemImage: systemImage, color: tint)
            }
        }
    }
}
