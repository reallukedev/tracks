import SwiftUI

#if os(iOS)
extension View {
    /// A page that opens on a `SettingsHero`: the bar takes the title only once the hero has
    /// scrolled away, so the name is never on screen twice.
    func settingsPage(_ title: LocalizedStringKey) -> some View {
        modifier(SettingsPageTitle(title: title))
    }
}

private struct SettingsPageTitle: ViewModifier {
    var title: LocalizedStringKey
    @State private var isHeroHidden = false

    func body(content: Content) -> some View {
        content
            .navigationTitle(isHeroHidden ? title : "")
            .navigationBarTitleDisplayMode(.inline)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // Roughly the hero's height at the default text size. A threshold on the
                // scroll offset, never a measured size fed back into layout.
                geometry.contentOffset.y + geometry.contentInsets.top > 150
            } action: { _, hidden in
                isHeroHidden = hidden
            }
    }
}
#endif

#if os(macOS)
import AppKit

extension View {
    /// A grouped form at the Settings window's width, as tall as its content up to what fits
    /// on screen, and scrolling past that.
    func settingsPane() -> some View {
        SettingsPaneLayout {
            self
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
        }
    }
}

/// The height comes from the form's ideal size, never from anything measured and stored, so
/// AppKit has nothing to loop on as the window resizes to each pane.
struct SettingsPaneLayout: Layout {
    static let width: CGFloat = 520

    private var tallest: CGFloat {
        max(420, (NSScreen.main?.visibleFrame.height ?? 900) - 160)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let form = subviews.first else { return .zero }
        let natural = form.sizeThatFits(ProposedViewSize(width: Self.width, height: nil)).height
        return CGSize(width: Self.width, height: min(natural, tallest))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
#endif
