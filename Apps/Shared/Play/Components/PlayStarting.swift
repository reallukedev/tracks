import SwiftUI

/// A Play button's symbol that turns into a spinner from the tap until the music starts.
///
/// The spinner waits a moment before it shows, so something that starts at once never
/// flickers; a lookup in Apple Music that takes a second shows it was heard.
struct PlayStartingIcon: View {
    let systemImage: String
    let isStarting: Bool
    /// The spinner's colour: the label's, on a prominent button whose words are white.
    var spinnerTint: Color? = nil
    @State private var showsSpinner = false

    var body: some View {
        Image(systemName: systemImage)
            // The symbol keeps its room, so the button doesn't change width.
            .opacity(showsSpinner ? 0 : 1)
            .overlay {
                if showsSpinner {
                    ProgressView()
                        .controlSize(.small)
                        .tint(spinnerTint)
                        .accessibilityHidden(true)
                }
            }
            .task(id: isStarting) {
                guard isStarting else {
                    showsSpinner = false
                    return
                }
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                showsSpinner = true
            }
    }
}

/// On a cover tapped to play, where its now-playing bars will go: a spinner until they do.
/// Shows a moment after the tap, as ``PlayStartingIcon`` does.
struct PlayStartingBadge: View {
    let isStarting: Bool
    @State private var isShown = false

    var body: some View {
        ZStack {
            if isShown {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .frame(width: 26, height: 26)
                    .background(.black.opacity(0.45), in: .circle)
                    .transition(.opacity)
                    .accessibilityLabel("Starting")
            }
        }
        .animation(.easeOut(duration: 0.15), value: isShown)
        .task(id: isStarting) {
            guard isStarting else {
                isShown = false
                return
            }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            isShown = true
        }
    }
}

extension View {
    /// Ends `isStarting` once `hasStarted` turns true, the player reports a problem, or it has
    /// waited long enough that a spinner would only be a worry.
    func endsPlayStart(_ isStarting: Binding<Bool>, hasStarted: Bool) -> some View {
        modifier(PlayStartEnding(isStarting: isStarting, hasStarted: hasStarted))
    }
}

private struct PlayStartEnding: ViewModifier {
    @Binding var isStarting: Bool
    let hasStarted: Bool
    @Environment(PlayerModel.self) private var player

    func body(content: Content) -> some View {
        content
            .onChange(of: hasStarted) { _, started in
                if started { isStarting = false }
            }
            .onChange(of: player.problem != nil) { _, failed in
                if failed { isStarting = false }
            }
            .task(id: isStarting) {
                guard isStarting else { return }
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                isStarting = false
            }
    }
}
