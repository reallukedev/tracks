import SwiftUI
import TracksCore

extension View {
    /// Re-reads a setting into the view's own state when another device changes it.
    ///
    /// Settings live in `UserDefaults`, which SwiftUI can't observe, and `CaptureSettings`
    /// isn't `@Observable`, so these sections keep a `@State` copy: a `Toggle` bound straight
    /// through the struct snaps back after each tap. `@AppStorage` redraws itself when
    /// ``SettingsSync`` writes a pulled value, but a `@State` copy taken when the view was
    /// first built would keep showing the old value until something else rebuilt it.
    ///
    /// The reload runs for any pulled key, not just the one this view shows. Re-reading a
    /// couple of defaults is cheaper than working out whether it was worth it, and settings
    /// arrive from another device a handful of times a day at most.
    func onSettingsChangedRemotely(perform reload: @escaping @MainActor () -> Void) -> some View {
        task {
            for await _ in NotificationCenter.default.notifications(
                named: SettingsSync.didChangeNotification
            ) {
                reload()
            }
        }
    }
}
