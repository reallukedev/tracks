import SwiftUI

/// A spinner that only appears if loading takes a while. Most pages work out their figures
/// in a blink, and a spinner shown for a frame or two reads as a flicker.
struct LateProgressView: View {
    var delay: Duration = .milliseconds(400)
    @State private var isShown = false

    var body: some View {
        ProgressView()
            .opacity(isShown ? 1 : 0)
            .task {
                try? await Task.sleep(for: delay)
                isShown = true
            }
    }
}
