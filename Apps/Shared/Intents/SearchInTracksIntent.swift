import AppIntents
#if os(macOS)
import AppKit
#endif

/// Opens Search with what was asked for already typed, for "Search Tracks for Mara Solis" and
/// Spotlight's searches in apps.
struct SearchInTracksIntent: ShowInAppSearchResultsIntent {
    static let title: LocalizedStringResource = "Search Tracks"
    static let description = IntentDescription(
        "Opens Search in Tracks with the words you give it.",
        categoryName: "Search"
    )
    static let searchScopes: [StringSearchScope] = [.general]

    @Parameter(title: "Search For")
    var criteria: StringSearchCriteria

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.beginSearch(for: criteria.term)
        #if os(macOS)
        // Tracks may be living in the menu bar with no window to show it in.
        if let openWindow = MacAppDelegate.openWindow {
            MainWindow.bringForward(openWindow: openWindow)
        } else {
            // No window has been shown yet to open another: reopening the app makes its main
            // window, which picks the search up.
            _ = try? await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
        }
        #endif
        return .result()
    }
}
