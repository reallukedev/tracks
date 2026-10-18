import SwiftUI

/// The version and the links out: last on the iPhone list, last in the Mac's General pane.
struct AboutSection: View {
    var body: some View {
        Section {
            LabeledContent("Version", value: Self.version)
            SettingsLinkRow(
                title: "Report a Problem",
                systemImage: "exclamationmark.bubble.fill",
                tint: .blue,
                destination: URL(string: "https://github.com/reallukedev/tracks/issues")!
            )
            SettingsLinkRow(
                title: "Privacy Policy",
                systemImage: "hand.raised.fill",
                tint: .blue,
                destination: URL(string: "https://github.com/reallukedev/tracks/blob/main/PRIVACY.md")!
            )
            SettingsLinkRow(
                title: "Source Code",
                systemImage: "chevron.left.forwardslash.chevron.right",
                tint: .gray,
                destination: URL(string: "https://github.com/reallukedev/tracks")!
            )
        } header: {
            Text("About")
        } footer: {
            Text("Tracks has no servers and no analytics. Your history stays on your devices and in your iCloud account.")
        }
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
