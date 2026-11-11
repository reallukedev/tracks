import SwiftUI

/// The library's revision as a statistics page should follow it: live while the page can be
/// seen, held while its window is minimized or covered or the app is in the background.
///
/// Someone who listens all day leaves Tracks open behind other windows, and each song would
/// otherwise recompute a page nobody is looking at. Once the page is seen again it reads the
/// latest revision and catches up in one go.
@MainActor
@propertyWrapper
struct SeenRevision: DynamicProperty {
    @Environment(AppModel.self) private var model
    @Environment(\.isOnScreen) private var isOnScreen
    @State private var held = Held()

    var wrappedValue: Int {
        // Not reading the revision while hidden is what keeps the page from updating at all.
        if isOnScreen { held.revision = model.library.revision }
        return held.revision
    }

    /// A box, so remembering the last revision seen doesn't itself update the view.
    private final class Held {
        var revision = 0
    }
}
