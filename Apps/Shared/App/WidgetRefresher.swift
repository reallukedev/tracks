import Foundation
import SwiftData
import WidgetKit
import TracksCore

/// Reloads the widgets when a save changes what they show.
///
/// Listens for the main context's saves instead of being called from each write, since the
/// writes live in TracksCore, which doesn't import WidgetKit. Every write goes through
/// `TracksStore.shared()`, so this sees all of them.
@MainActor
final class WidgetRefresher {
    /// One per process. Shared so a background intent can flush it before it's suspended.
    static let shared: WidgetRefresher? = (try? TracksStore.shared()).map { WidgetRefresher(store: $0) }

    /// How long to collect saves before checking. A Mac capture saves the row, then its
    /// catalog id and cover a second or two later, then the playlist write and scrobble.
    /// Waiting a few seconds usually turns that into one reload.
    private static let settle: Duration = .seconds(5)

    private let store: TracksStore
    private let settings: CaptureSettings
    /// What the widgets showed at the last reload, or nil if unknown.
    private var faces: WidgetFaces?
    private var pendingCheck: Task<Void, Never>?

    private init(store: TracksStore, settings: CaptureSettings = CaptureSettings()) {
        self.store = store
        self.settings = settings
        // Starting from the current state means a launch doesn't cost a reload by itself.
        faces = currentFaces()
        Self.reloadAfterUpdate()
        // Lives as long as the process, so the observer is never removed.
        NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: store.context,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saved() }
        }
    }

    /// Checks once, a few seconds after the first save. The timer doesn't restart on later
    /// saves, so a steady stream of them can't keep putting the check off.
    private func saved() {
        guard pendingCheck == nil else { return }
        pendingCheck = Task { [weak self] in
            try? await Task.sleep(for: Self.settle)
            guard !Task.isCancelled else { return }
            self?.reloadIfChanged()
        }
    }

    /// Reloads each widget kind whose content changed since the last reload. Call it
    /// directly when the process may be suspended before the settle timer fires.
    func reloadIfChanged() {
        pendingCheck?.cancel()
        pendingCheck = nil
        // If the read fails, leave it to the widgets' own refresh schedule.
        guard let now = currentFaces() else { return }
        let changed = faces.map { now.kindsChanged(since: $0) }
            ?? [WidgetKind.lastPlayed, WidgetKind.today, WidgetKind.listening]
        faces = now
        for kind in changed {
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
    }

    /// Reloads every widget on the first launch of a new build.
    ///
    /// An update can change the store's schema, and a widget can only open it read-only, so
    /// it can't migrate the store itself. Until the app has, the widget says it can't read
    /// captures. This launch just migrated it, so the widgets are told straight away rather
    /// than at their next scheduled refresh.
    private static func reloadAfterUpdate(defaults: UserDefaults = .standard) {
        let key = "widgetsReloadedForBuild"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        guard defaults.string(forKey: key) != build else { return }
        defaults.set(build, forKey: key)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func currentFaces() -> WidgetFaces? {
        try? store.widgetFaces(showsUpNext: settings.showsUpNextInWidget)
    }
}
