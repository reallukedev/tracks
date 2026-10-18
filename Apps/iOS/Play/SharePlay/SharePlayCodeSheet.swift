import SwiftUI
import TracksCore

/// The code on this iPhone, for the people with you to scan with their Camera, as Wallet shows
/// a pass: large, on white, with the screen turned up and kept awake while it's out. They land
/// in Tracks, on the same page as someone invited in Messages.
///
/// The code works while the sheet is up, and for as long as anyone who joined with it stays.
struct SharePlayCodeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var codeImage: UIImage?
    @State private var screen = ScreenForCode()
    private var sharePlay = SharePlayController.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    code
                    Text(title)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                        .padding(.top, 28)
                    Text(message)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                    if sharePlay.codeStatus == .needsLocalNetwork {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 20)
                    } else {
                        people
                            .padding(.top, 20)
                    }
                    // In the page rather than pinned under it, so large text never runs
                    // under the buttons.
                    actions
                        .padding(.top, 36)
                }
                .padding(.horizontal, 32)
                .padding(.top, 12)
                .padding(.bottom, 24)
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle("SharePlay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task(id: sharePlay.invite) {
            guard let invite = sharePlay.invite else { return }
            codeImage = SharePlayCodeImage.image(for: invite, side: Self.codeSide, scale: 3)
        }
        .onAppear {
            sharePlay.showCode(on: .phone)
            screen.brighten()
        }
        .onDisappear {
            sharePlay.hideCode(on: .phone)
            screen.restore()
        }
        .onChange(of: scenePhase) { _, phase in
            // Back as it was while Tracks’ away, as Wallet leaves it.
            if phase == .active { screen.brighten() } else { screen.restore() }
        }
        // Ended here or from the menu: nothing left to show.
        .onChange(of: sharePlay.role) { _, role in
            if role != .host { dismiss() }
        }
        .sensoryFeedback(.success, trigger: sharePlay.guestCount) { old, new in new > old }
    }

    private static let codeSide: CGFloat = 280

    // MARK: - The code

    @ViewBuilder
    private var code: some View {
        ZStack {
            switch sharePlay.codeStatus {
            case .needsLocalNetwork:
                unavailable(systemImage: "network.slash")
            case .failed:
                unavailable(systemImage: "qrcode")
                    .overlay(alignment: .bottom) {
                        ProgressView()
                            .padding(.bottom, 32)
                    }
            case .off, .starting, .ready:
                if let codeImage {
                    Image(uiImage: codeImage)
                        .interpolation(.none)
                        .resizable()
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(.rect(cornerRadius: 28, style: .continuous))
                        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
                        .accessibilityLabel("SharePlay Code")
                        .accessibilityHint("Scan it with the Camera on another iPhone to join")
                        .transition(.opacity)
                } else {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(.white)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: Self.codeSide)
        .animation(.easeOut(duration: 0.2), value: codeImage == nil)
    }

    /// In the code's place when there's no code to scan.
    private func unavailable(systemImage: String) -> some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(.fill.tertiary)
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: 64, weight: .regular))
                    .foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)
    }

    private var title: LocalizedStringKey {
        switch sharePlay.codeStatus {
        case .needsLocalNetwork: "Local Network Is Off"
        case .failed: "Getting the Code Ready"
        default: "Scan to Add Songs"
        }
    }

    private var message: LocalizedStringKey {
        switch sharePlay.codeStatus {
        case .needsLocalNetwork: "People nearby can join with a code once Local Network is on for Tracks. You can still invite them in Messages."
        case .failed: "This iPhone couldn't offer itself nearby. It's trying again."
        default: SharePlayCodeImage.isForEveryone
            ? "Point an iPhone's Camera at this code to add songs to your Up Next. No app needed."
            : "Point the Camera on an iPhone with Tracks at this code to add songs to your Up Next."
        }
    }

    // MARK: - Who's joined

    private var people: some View {
        let count = sharePlay.guestCount
        return Label {
            Text(SharePlayWords.people(count))
                .contentTransition(.numericText(value: Double(count)))
        } icon: {
            Image(systemName: count > 0 ? "person.2.fill" : "person.2")
                .contentTransition(.symbolEffect(.replace))
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(count > 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.fill.quaternary, in: .capsule)
        .animation(PlayMotion.value, value: count)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 12) {
            ShareLink(item: SharePlayActivity(), preview: SharePlayActivity.preview) {
                Label("Invite in Messages…", systemImage: "message")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            if sharePlay.guestCount > 0 {
                Button("End SharePlay", role: .destructive) {
                    sharePlay.endHosting()
                }
                .buttonStyle(.borderless)
                .controlSize(.large)
            }
        }
    }
}

/// The screen turned all the way up while the code's out, for a camera to read it in
/// sunlight, and kept awake; both put back as they were once it's gone.
@MainActor
private struct ScreenForCode {
    /// The screen turned up, and how bright it was.
    private weak var screen: UIScreen?
    private var brightness: CGFloat?
    private var wasIdleTimerDisabled = false

    mutating func brighten() {
        guard brightness == nil else { return }
        let active = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard let screen = active?.screen else { return }
        self.screen = screen
        brightness = screen.brightness
        wasIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        screen.brightness = 1
    }

    mutating func restore() {
        guard let brightness else { return }
        screen?.brightness = brightness
        UIApplication.shared.isIdleTimerDisabled = wasIdleTimerDisabled
        self.brightness = nil
        screen = nil
    }
}
