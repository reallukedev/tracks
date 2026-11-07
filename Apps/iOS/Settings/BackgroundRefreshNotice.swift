import SwiftUI

/// Whether Tracks is actually catching up in the background, and when it last did.
///
/// Background App Refresh is opportunistic: iOS decides when, from how often Tracks is used
/// and the battery, and it may be hours or not at all. Without this the feature is invisible,
/// and "iOS hasn't woken us yet" looks exactly like "this never worked".
struct BackgroundRefreshNotice: View {
    private let availability = BackgroundRefreshAvailability.shared
    @Environment(\.openURL) private var openURL
    /// Read once when Settings opens; a background run can't happen while it's on screen.
    @State private var lastRun = BackgroundRefresh.lastRun
    @State private var lastError = BackgroundRefresh.lastError

    var body: some View {
        if let blocker = availability.blocker {
            VStack(alignment: .leading, spacing: SettingsSpacing.standard) {
                Label {
                    Text(message(for: blocker))
                        .font(.subheadline)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.ink(.orange))
                }
                // Opens Tracks’ page in Settings, which has the Background App Refresh switch.
                if blocker == .turnedOff, let url = URL(string: UIApplication.openSettingsURLString) {
                    Button("Open Settings…") { openURL(url) }
                }
            }
            .padding(.vertical, 2)
        } else if let lastError {
            // An unaccepted request is the more useful thing to say, since it means no
            // wake-up is even pending. It's a sentence, so it goes under the label.
            LabeledContent {
                Text("Not Scheduled")
            } label: {
                Text("Last Background Check")
                Text(lastError)
            }
        } else {
            LabeledContent("Last Background Check", value: status)
        }
    }

    /// When iOS last woke Tracks.
    private var status: String {
        guard let lastRun else { return String(localized: "Not Yet") }
        return Format.relativeTime(lastRun)
    }

    private func message(for blocker: BackgroundRefreshAvailability.Blocker) -> LocalizedStringKey {
        switch blocker {
        case .lowPowerMode:
            "Low Power Mode is on, so Tracks only catches up when you open it."
        case .turnedOff:
            "Background App Refresh is off for Tracks, so it only catches up when you open it."
        case .restricted:
            "Background App Refresh isn't allowed on this device, so Tracks only catches up when you open it."
        }
    }
}
