import SwiftUI
import TracksCore

/// The app's one search: what's typed and where it looks. It outlives the page, so leaving
/// Search and coming back finds it as it was, as Music's does, and Siri, ⌘F and an empty page's
/// "Search Apple Music" all reach the same field.
@Observable
@MainActor
final class SearchSession {
    var query = LaunchScene.searchText ?? ""

    var scope: SearchScope {
        didSet { UserDefaults.standard.set(scope.rawValue, forKey: Self.scopeKey) }
    }

    /// Set to put the cursor in the field once the page is showing.
    var wantsFocus = false

    /// Whether Identify Song is listening or showing what it heard.
    var isIdentifying = false

    #if os(iOS)
    /// The Search tab's stack, so starting a search can come back out of a page pushed on it.
    var path = NavigationPath()
    #endif

    private static let scopeKey = "searchScope"

    init() {
        // The scope last used before search was one page, where each screen kept its own.
        let defaults = UserDefaults.standard
        let stored = defaults.string(forKey: Self.scopeKey)
            ?? defaults.string(forKey: "macSearchScope")
            ?? defaults.string(forKey: "playSearchScope")
        scope = stored.flatMap(SearchScope.init(rawValue:)) ?? .appleMusic
    }

    /// A scope the source doesn't have, Apple Music's catalog with your own music playing, falls
    /// back to the first it does.
    func keepScope(for source: MusicSource) {
        let scopes = SearchScope.scopes(for: source)
        if !scopes.contains(scope) { scope = scopes[0] }
    }

    /// Remembers what's typed in the scope's recent searches.
    func remember(source: MusicSource) {
        let key = scope.recentsKey(for: source)
        let stored = UserDefaults.standard.string(forKey: key) ?? ""
        UserDefaults.standard.set(RecentSearches.adding(query, to: stored), forKey: key)
    }
}

extension AppModel {
    /// Opens Search with the cursor in its field: in a scope, with text, when given.
    func beginSearch(in scope: SearchScope? = nil, for text: String? = nil) {
        if let scope { search.scope = scope }
        if let text { search.query = text }
        search.keepScope(for: musicSource)
        search.wantsFocus = true
        // Out of any page opened from a result, back to the field.
        #if os(macOS)
        if sidebarSelection == .search { playNavigator.path = NavigationPath() }
        sidebarSelection = .search
        #else
        search.path = NavigationPath()
        selectedTab = .search
        #endif
    }
}
