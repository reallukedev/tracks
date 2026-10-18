import SwiftUI

/// The top of a settings page: its tile, its name, and one line on how it stands.
///
/// iPhone centers it, as Settings opens a feature; the Mac sets it in a row with room for the
/// one control that belongs to the whole pane, as System Settings' panes do.
struct SettingsHero<Accessory: View>: View {
    var title: LocalizedStringKey
    var subtitle: Text
    var systemImage: String
    var tint: Color
    var accessory: Accessory

    init(
        _ title: LocalizedStringKey,
        subtitle: Text,
        systemImage: String,
        tint: Color,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.accessory = accessory()
    }

    var body: some View {
        Section {
            #if os(macOS)
            HStack(spacing: SettingsSpacing.row) {
                SettingsIconTile(systemImage: systemImage, color: tint, baseSide: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    subtitle
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                accessory
            }
            .padding(.vertical, 2)
            #else
            VStack(spacing: SettingsSpacing.row) {
                SettingsIconTile(systemImage: systemImage, color: tint, baseSide: 64)
                VStack(spacing: SettingsSpacing.tight) {
                    Text(title)
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    subtitle
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .contentTransition(.opacity)
                }
                accessory
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, SettingsSpacing.tight)
            .listRowBackground(Color.clear)
            .accessibilityElement(children: .combine)
            #endif
        }
    }
}

extension SettingsHero where Accessory == EmptyView {
    init(_ title: LocalizedStringKey, subtitle: Text, systemImage: String, tint: Color) {
        self.init(title, subtitle: subtitle, systemImage: systemImage, tint: tint) { EmptyView() }
    }
}
