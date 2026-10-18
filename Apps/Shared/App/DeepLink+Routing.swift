import SwiftUI
import TracksCore

/// Following a ``DeepLink`` inside the app.
///
/// A file of its own because ``DeepLink`` is also compiled into the widget extension, which
/// has no `AppModel` or `Route`.
extension DeepLink {
    /// The page to push, if the link is for one.
    var route: Route? {
        switch self {
        case .summary, .history:
            nil
        case .song(let title, let artistName):
            // A song's page is keyed the way `CaptureStat.songIdentity` groups its plays.
            .song(HistoryImport.key(title: title, artistName: artistName))
        }
    }

    /// Moves the app to where the link points. A song goes through `pendingRoute`, which the
    /// window pushes and clears, the same way the menu bar opens a song.
    func open(in model: AppModel) {
        switch self {
        case .summary:
            #if os(iOS)
            model.selectedTab = .summary
            #else
            model.sidebarSelection = .summary
            #endif
        case .history:
            #if os(iOS)
            model.selectedTab = .history
            #else
            model.sidebarSelection = .history
            #endif
        case .song:
            model.pendingRoute = route
        }
    }
}

extension View {
    /// Follows `tracks://` links from the widgets, and on iPhone takes in songs opened in
    /// Tracks from Files or the share sheet, into Your Music, and joins the SharePlay whose
    /// code was scanned with the Camera.
    func opensDeepLinks(in model: AppModel) -> some View {
        onOpenURL { url in
            #if os(iOS)
            if url.isFileURL {
                model.openInYourMusic([url])
                return
            }
            if let invite = SharePlayInvite(url: url) {
                SharePlayController.shared.join(invite)
                return
            }
            #endif
            DeepLink(url: url)?.open(in: model)
        }
        #if os(iOS)
        // A SharePlay code holding the App Clip's link, scanned with Tracks installed: iOS
        // opens Tracks rather than the App Clip, with the link.
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            guard let url = activity.webpageURL, let invite = SharePlayInvite(url: url) else { return }
            SharePlayController.shared.join(invite)
        }
        #endif
    }
}
