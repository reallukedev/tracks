import SwiftUI

/// Chooses between the app and the headless probe before any UI exists. `TracksApp` isn't
/// `@main` because `App.main()` creates a window.
@main
struct Main {
    static func main() {
        #if DEBUG
        // Diagnostics for development only. Some commands write to the music library.
        let arguments = CommandLine.arguments
        if HeadlessProbe.shouldRun(arguments) {
            HeadlessProbe.run(arguments)
        }
        #endif
        TracksApp.main()
    }
}
