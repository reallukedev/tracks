import SwiftUI
import AuthenticationServices
import TracksCore

/// Connecting a Last.fm account, and what gets sent. An iPhone page, and the Mac's Last.fm
/// pane.
struct LastFMSettingsPage: View {
    /// Owned by whoever shows the page, so an approval still pending on Last.fm survives
    /// going back to the list.
    var connection: LastFMConnection

    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuthentication
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(CaptureSettings.scrobblesToLastFMKey, store: CaptureSettings.sharedDefaults)
    private var scrobbles = true
    @AppStorage(CaptureSettings.scrobblesImportedKey, store: CaptureSettings.sharedDefaults)
    private var scrobblesRecovered = true
    /// Asks whether to import the account's history, once, right after it connects.
    @State private var offersImport = false

    private var status: LastFMSettingsStatus {
        LastFMSettingsStatus(connection.state, scrobbles: scrobbles)
    }

    var body: some View {
        Form {
            hero
            #if os(iOS)
            if !status.isConnected {
                connectSection
            }
            #endif
            if let username = connectedUsername {
                scrobblingSection
                if let history = model.lastFMHistory {
                    LastFMHistorySection(state: history.state, action: history.startOrStop)
                }
                accountSection(username)
                disconnectSection
            }
        }
        .animation(SettingsMotion.row(reduceMotion: reduceMotion), value: status.isConnected)
        .animation(SettingsMotion.row(reduceMotion: reduceMotion), value: scrobbles)
        .onChange(of: connection.state) { old, new in
            offerImportIfJustConnected(from: old, to: new)
        }
        .alert("Import Your Last.fm History?", isPresented: $offersImport) {
            Button("Import") { model.lastFMHistory?.start() }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text(LastFMHistoryWords.offerMessage)
        }
        #if os(macOS)
        .settingsPane()
        #else
        .settingsPage("Last.fm")
        #endif
    }

    private var connectedUsername: String? {
        if case .connected(let username) = connection.state { return username }
        return nil
    }

    private var hero: some View {
        SettingsHero(
            "Last.fm",
            subtitle: status.tone.apply(to: Text(status.line)),
            systemImage: "waveform",
            tint: .red
        ) {
            heroControl
        }
    }

    private var connectSection: some View {
        Section {
            connectButton
        } footer: {
            Text("Tracks opens Last.fm so you can allow it. Your password is never shared with Tracks.")
        }
    }

    // MARK: - Connecting

    /// The pane's one control on the Mac. On iPhone, connecting is a row of its own.
    @ViewBuilder
    private var heroControl: some View {
        #if os(macOS)
        switch connection.state {
        case .idle, .failed:
            connectButton
        case .waitingForBrowser:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Button("Cancel", action: connection.cancel)
            }
        case .connected:
            EmptyView()
        }
        #endif
    }

    private var connectButton: some View {
        Button {
            connect()
        } label: {
            #if os(macOS)
            Text("Connect…")
            #else
            HStack {
                Text(connection.state == .waitingForBrowser ? "Waiting for Last.fm…" : "Connect to Last.fm…")
                Spacer()
                if connection.state == .waitingForBrowser {
                    ProgressView()
                }
            }
            #endif
        }
        .disabled(connection.state == .waitingForBrowser)
    }

    private func connect() {
        connection.connect(waitsForPage: isIOS) { url in
            #if os(iOS)
            // Last.fm doesn't redirect back after approval, so this returns when the person
            // closes the sheet (or when it's cancelled after the poll succeeds).
            _ = try? await webAuthentication.authenticate(
                using: url,
                callbackURLScheme: "tracks",
                preferredBrowserSession: .shared
            )
            #else
            openURL(url)
            #endif
        }
    }

    /// Offers the import when an account has just been approved, not when the page opens on
    /// one connected before, and only if this account's history isn't already in.
    private func offerImportIfJustConnected(from old: LastFMConnection.State, to new: LastFMConnection.State) {
        guard let history = model.lastFMHistory else { return }
        history.readProgress()
        guard old == .waitingForBrowser, case .connected = new, history.state == .notImported else { return }
        Task {
            // On iPhone Last.fm's sheet is still closing, and an alert asked for while it
            // does never appears.
            try? await Task.sleep(for: .milliseconds(isIOS ? 700 : 0))
            offersImport = true
        }
    }

    private var isIOS: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    // MARK: - Connected

    private var scrobblingSection: some View {
        Section {
            SettingsSwitch(
                "Scrobble What You Play",
                detail: scrobbles
                    ? Text("Every song Tracks keeps goes to Last.fm, radio included.")
                    : Text("Nothing is sent to Last.fm until you turn this back on."),
                isOn: $scrobbles
            )
            if scrobbles {
                SettingsSwitch(
                    "Include Recovered Songs",
                    detail: scrobblesRecovered
                        ? Text("Sent with the time Tracks found them, since Recently Played doesn’t say when you played them.")
                        : Text("Songs recovered from Recently Played stay off Last.fm, so nothing arrives with a guessed time."),
                    isOn: $scrobblesRecovered
                )
            }
        } header: {
            Text("Scrobbling")
        } footer: {
            #if os(iOS)
            Text(scrobblingFooter)
                .contentTransition(.opacity)
            #endif
        }
    }

    #if os(iOS)
    private var scrobblingFooter: LocalizedStringKey {
        switch (scrobbles, scrobblesRecovered) {
        case (false, _):
            "Nothing is sent to Last.fm until you turn scrobbling back on."
        case (true, true):
            "Every song Tracks keeps is scrobbled, radio included. Recovered songs are sent with the time Tracks found them, because Apple Music’s Recently Played doesn’t say when you played them."
        case (true, false):
            "Every song Tracks keeps is scrobbled, radio included. Songs recovered from Recently Played are left out, so nothing reaches Last.fm with a guessed time."
        }
    }
    #endif

    private func accountSection(_ username: String) -> some View {
        Section {
            LabeledContent("Signed In As", value: username)
            if let profile = URL(string: "https://www.last.fm/user/\(username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? username)") {
                SettingsLinkRow(title: "Open Your Profile", systemImage: "person.crop.circle", tint: .red, destination: profile)
            }
        } header: {
            Text("Account")
        }
    }

    /// Stops an import too. How far it got is kept for this account, so connecting it again
    /// carries on from there.
    private func disconnect() {
        model.lastFMHistory?.stop()
        connection.disconnect()
    }

    private var disconnectSection: some View {
        Section {
            #if os(macOS)
            SettingsDetailRow(
                title: Text("Disconnect"),
                detail: Text("Tracks stops scrobbling. What’s already on Last.fm stays there.")
            ) {
                Button("Disconnect", role: .destructive, action: disconnect)
            }
            #else
            Button("Disconnect", role: .destructive, action: disconnect)
            #endif
        } footer: {
            #if os(iOS)
            Text("Tracks stops scrobbling. What’s already on Last.fm stays there.")
            #endif
        }
    }
}

extension LastFMSettingsStatus {
    /// Where a live connection stands, as Settings says it.
    init(_ state: LastFMConnection.State, scrobbles: Bool) {
        switch state {
        case .idle: self = .notSetUp
        case .waitingForBrowser: self = .connecting
        case .connected(let username): self = .connected(username: username, scrobbles: scrobbles)
        case .failed(let message): self = .failed(message)
        }
    }
}

extension LastFMSessionStore {
    /// The defaults key holding the connected username, in `CaptureSettings.sharedDefaults`.
    /// The same string as TracksCore's internal `usernameKey`, which can't be renamed without
    /// signing everyone out.
    ///
    /// Views watch it with `@AppStorage` to follow connecting and disconnecting. Saving and
    /// clearing a session write it after the Keychain, so when it changes, ``current`` is
    /// already up to date.
    static let usernameDefaultsKey = "TracksLastFMUsername"
}
