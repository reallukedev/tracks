import SwiftUI

/// Refreshes the page in front, from the Mac's View > Refresh (⌘R).
struct RefreshPageAction {
    let refresh: RefreshAction

    @MainActor
    func callAsFunction() {
        Task { await refresh() }
    }
}

extension FocusedValues {
    @Entry var refreshPage: RefreshPageAction?
}

extension View {
    /// Offers the page's pull to refresh to View > Refresh on the Mac. Goes just inside the
    /// page's `.refreshable`, where its action is.
    func refreshCommand() -> some View {
        modifier(RefreshCommandModifier())
    }
}

private struct RefreshCommandModifier: ViewModifier {
    @Environment(\.refresh) private var refresh
    /// Off while another page is pushed over this one or the full player covers it.
    @Environment(\.isOnScreen) private var isOnScreen

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .focusedSceneValue(\.refreshPage, isOnScreen ? refresh.map(RefreshPageAction.init) : nil)
        #else
        content
        #endif
    }
}
