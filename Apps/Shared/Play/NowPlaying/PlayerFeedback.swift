import SwiftUI
import MusicKit

extension View {
    /// The player's alerts, Apple's subscription offer and its confirmations. On the tab view,
    /// and on Now Playing, which covers it: a presentation under a full-screen cover can't show.
    ///
    /// - Parameter isActive: false where something above shows them instead.
    func playerFeedback(isActive: Bool = true) -> some View {
        modifier(PlayerFeedback(isActive: isActive))
    }
}

private struct PlayerFeedback: ViewModifier {
    let isActive: Bool
    @Environment(PlayerModel.self) private var player
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var showsSubscriptionOffer = false

    func body(content: Content) -> some View {
        @Bindable var player = player
        content
            .alert(
                player.problem?.title ?? "",
                isPresented: isActive ? $player.isShowingProblem : .constant(false),
                presenting: player.problem
            ) { problem in
                switch problem {
                case .accessDenied:
                    Button("Open Settings") {
                        if let url = SystemSettingsLink.musicAccess { openURL(url) }
                    }
                    Button("Cancel", role: .cancel) {}
                case .needsSubscription(let canSubscribe):
                    if canSubscribe {
                        Button("Try Apple Music") { showsSubscriptionOffer = true }
                    }
                    Button("Not Now", role: .cancel) {}
                case .needsAppleMusic:
                    Button("Use Apple Music") { model.musicSource = .appleMusic }
                    Button("Not Now", role: .cancel) {}
                case .blockedArtist(let name):
                    // Stopped for being theirs: unblocked, it plays on from where it stopped.
                    Button("Unblock and Play") {
                        player.unblock(artist: name)
                        if player.hasQueue, !player.isPlaying { player.togglePlayPause() }
                    }
                    Button("Cancel", role: .cancel) {}
                case .nothingToPlay, .onlyExplicit, .explicitSong, .notInYourMusic, .failed:
                    Button("OK", role: .cancel) {}
                }
            } message: { problem in
                Text(problem.message)
            }
            .musicSubscriptionOffer(isPresented: $showsSubscriptionOffer, options: .init(messageIdentifier: .playMusic))
            .overlay {
                if isActive {
                    ConfirmationHUD(message: player.confirmation)
                }
            }
            // "Added to Library" is felt as it shows; a problem, as its alert comes up.
            .sensoryFeedback(.success, trigger: player.confirmation) { _, message in isActive && message != nil }
            .sensoryFeedback(.error, trigger: player.isShowingProblem) { _, showing in isActive && showing }
    }
}

/// "Added to Library", over everything for a moment, as Music confirms.
struct ConfirmationHUD: View {
    let message: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let message {
                Label(message, systemImage: "checkmark")
                    .font(.headline)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .glassEffect(.regular, in: .capsule)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
                    .onAppear { AccessibilityNotification.Announcement(message).post() }
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: message)
        .allowsHitTesting(false)
    }
}
