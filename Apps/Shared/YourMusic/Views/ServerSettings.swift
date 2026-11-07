import SwiftUI
import TracksCore

/// Your servers, in Settings: each with whether it's reachable and how much is on it. On
/// iPhone each row pushes its page; a Mac Settings pane has nowhere to push, so each row
/// carries its actions in a menu and a context menu instead.
struct ServersSection: View {
    @Environment(YourMusic.self) private var music
    /// `-TracksConnectServer YES` opens the form at once, for screenshots.
    @State private var addsServer = Self.opensForm

    private static var opensForm: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "TracksConnectServer")
        #else
        false
        #endif
    }

    var body: some View {
        Section {
            ForEach(music.servers.servers) { server in
                #if os(macOS)
                MacServerRow(server: server)
                #else
                NavigationLink {
                    ServerDetailPage(serverID: server.id)
                } label: {
                    ServerRow(server: server)
                }
                #endif
            }
            #if os(macOS)
            HStack {
                Spacer()
                Button("Connect a Server…") { addsServer = true }
            }
            #else
            Button("Connect a Server…", systemImage: "plus") { addsServer = true }
            #endif
        } header: {
            Text("Servers")
        } footer: {
            Text("Play and download from your own music server: Navidrome, Gonic, Airsonic, Ampache and any other that speaks the Subsonic API.")
        }
        .sheet(isPresented: $addsServer) {
            ServerForm()
        }
    }
}

/// A server with its status, as a row.
struct ServerRow: View {
    let server: SubsonicServer
    @Environment(YourMusic.self) private var music

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                #if os(macOS)
                .font(.title2)
                #else
                .font(.title3)
                #endif
                .foregroundStyle(.tint)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                Text(statusLine)
                    #if os(macOS)
                    .font(.caption)
                    #else
                    .font(.subheadline)
                    #endif
                    .foregroundStyle(problem ? AnyShapeStyle(.ink(.orange)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
        }
    }

    /// Out of reach or refusing the password: something the person may want to fix.
    private var problem: Bool {
        switch music.servers.status[server.id] {
        case .offline, .wrongPassword, .failed: true
        default: false
        }
    }

    private var statusLine: String {
        if music.servers.syncing.contains(server.id) { return String(localized: "Syncing…") }
        let count = music.servers.catalogs[server.id]?.count ?? 0
        let songs = String(AttributedString(localized: "^[\(count) song](inflect: true)").characters)
        switch music.servers.status[server.id] {
        case .online:
            // Connected and empty reads differently from out of reach.
            guard count > 0 else { return String(localized: "Connected · No songs yet") }
            #if os(macOS)
            return "\(songs) · \(server.url.host() ?? server.url.absoluteString)"
            #else
            return songs
            #endif
        case .connecting: return String(localized: "Connecting…")
        case .offline: return String(localized: "Can’t be reached · \(songs)")
        case .wrongPassword: return String(localized: "Password needed")
        case .failed(let reason): return reason
        case nil: return songs
        }
    }
}

/// What removing a server takes with it, counted, for its confirmation.
private struct ServerRemoval {
    let title: String
    let message: String
    let downloadIDs: Set<String>

    @MainActor
    init(_ server: SubsonicServer, music: YourMusic) {
        downloadIDs = Set(music.downloads.items.values.filter { $0.track.serverID == server.id }.map(\.track.id))
        let songs = music.servers.catalogs[server.id]?.count ?? 0
        title = String(localized: "Remove \u{201C}\(server.name)\u{201D}?")
        let songWords = String(AttributedString(localized: "^[\(songs) song](inflect: true)").characters)
        let downloadWords = String(AttributedString(localized: "^[\(downloadIDs.count) download](inflect: true)").characters)
        message = downloadIDs.isEmpty
            ? String(localized: "Its \(songWords) leave Tracks. Your plays of them stay in your history.")
            : String(localized: "Its \(songWords) and \(downloadWords) leave Tracks. Your plays of them stay in your history.")
    }

    @MainActor
    func perform(_ serverID: String, music: YourMusic) {
        music.downloads.remove(downloadIDs)
        music.servers.remove(serverID)
    }
}

#if os(macOS)
/// A server in the Mac pane: its status, and its actions in a ••• menu and a context menu.
private struct MacServerRow: View {
    let server: SubsonicServer
    @Environment(YourMusic.self) private var music
    @State private var editsServer = false
    @State private var confirmsRemove = false

    var body: some View {
        let removal = ServerRemoval(server, music: music)
        HStack(spacing: SettingsSpacing.row) {
            ServerRow(server: server)
                .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .accessibilityLabel(Text("More for \(server.name)"))
        }
        .padding(.vertical, 2)
        .contextMenu { actions }
        .sheet(isPresented: $editsServer) {
            ServerForm(editing: server)
        }
        .confirmationDialog(removal.title, isPresented: $confirmsRemove, titleVisibility: .visible) {
            Button("Remove Server", role: .destructive) { removal.perform(server.id, music: music) }
        } message: {
            Text(removal.message)
        }
    }

    @ViewBuilder
    private var actions: some View {
        let isSyncing = music.servers.syncing.contains(server.id)
        Button("Check Connection", systemImage: "antenna.radiowaves.left.and.right") {
            Task { await music.servers.connect(server.id) }
        }
        Button(isSyncing ? "Syncing…" : "Sync Now", systemImage: "arrow.triangle.2.circlepath") {
            Task { await music.servers.sync(server.id) }
        }
        .disabled(isSyncing)
        Button("Change Password or Address…", systemImage: "key") { editsServer = true }
        Divider()
        Toggle("Tell Server About Plays", isOn: Binding(
            get: { music.servers.reportsPlays(to: server.id) },
            set: { music.servers.setReportsPlays($0, to: server.id) }
        ))
        Divider()
        Button("Remove Server…", systemImage: "trash", role: .destructive) { confirmsRemove = true }
    }
}
#endif

/// One server: sync it, change its password, or remove it.
struct ServerDetailPage: View {
    let serverID: String
    @Environment(YourMusic.self) private var music
    @Environment(\.dismiss) private var dismiss
    @State private var editsServer = false
    @State private var confirmsRemove = false

    var body: some View {
        if let server = music.servers.server(serverID) {
            let removal = ServerRemoval(server, music: music)
            let isSyncing = music.servers.syncing.contains(serverID)
            Form {
                Section {
                    ServerRow(server: server)
                    LabeledContent("Address", value: server.url.absoluteString)
                    LabeledContent("Username", value: server.username)
                }
                Section {
                    Button {
                        Task { await music.servers.connect(serverID) }
                    } label: {
                        Label("Check Connection", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    Button {
                        Task { await music.servers.sync(serverID) }
                    } label: {
                        HStack {
                            Label(isSyncing ? "Syncing…" : "Sync Now", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            if isSyncing { ProgressView() }
                        }
                    }
                    .disabled(isSyncing)
                    Button("Change Password or Address…", systemImage: "key") { editsServer = true }
                } footer: {
                    Text("Tracks syncs the list of songs on your server each day, so Tracks Radio, your mixes and search reach all of it. The songs themselves stream as you play them, unless you download them.")
                }
                Section {
                    Toggle("Tell Server About Plays", isOn: Binding(
                        get: { music.servers.reportsPlays(to: serverID) },
                        set: { music.servers.setReportsPlays($0, to: serverID) }
                    ))
                } footer: {
                    Text("Keeps your server’s play counts right. If your server sends your plays on to Last.fm or ListenBrainz and Tracks scrobbles to Last.fm too, turn one of them off so songs aren’t counted twice.")
                }
                Section {
                    Button("Remove Server…", role: .destructive) { confirmsRemove = true }
                        .confirmationDialog(removal.title, isPresented: $confirmsRemove, titleVisibility: .visible) {
                            Button("Remove Server", role: .destructive) {
                                removal.perform(serverID, music: music)
                                dismiss()
                            }
                        } message: {
                            Text(removal.message)
                        }
                }
            }
            .navigationTitle(server.name)
            .toolbarTitleDisplayMode(.inline)
            .sheet(isPresented: $editsServer) {
                ServerForm(editing: server)
            }
        }
    }
}

/// Connecting a server, or changing one: its address, username and password, checked before
/// they're kept. On iPhone a sheet with its actions in the bar; on the Mac a sheet with its
/// title in the content and its actions at the foot.
struct ServerForm: View {
    var editing: SubsonicServer?
    @Environment(YourMusic.self) private var music
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var problem: String?
    @FocusState private var focus: Field?

    private enum Field { case address, username, password, name }

    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: SettingsSpacing.tight) {
                Text(title)
                    .font(.title2.bold())
                Text(editing == nil
                    ? "Navidrome, Gonic, Airsonic, Ampache, LMS or any other server that speaks the Subsonic API."
                    : "Tracks checks the server answers before it keeps the change.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 20)

            form
                .disabled(isConnecting)
                .settingsPane()

            HStack(spacing: SettingsSpacing.standard) {
                if isConnecting {
                    ProgressView()
                        .controlSize(.small)
                    Text("Connecting…")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(editing == nil ? "Connect" : "Save", action: connect)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConnect || isConnecting)
            }
            // The form ends in its own inset, so the bar needs none above it.
            .padding([.horizontal, .bottom], 20)
        }
        .onAppear(perform: fillIn)
        #else
        NavigationStack {
            form
                .navigationTitle(title)
                .toolbarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", systemImage: "xmark") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if isConnecting {
                            ProgressView()
                        } else {
                            Button(editing == nil ? "Connect" : "Save", systemImage: "checkmark", action: connect)
                                .disabled(!canConnect)
                        }
                    }
                }
                .disabled(isConnecting)
                .onAppear(perform: fillIn)
        }
        .interactiveDismissDisabled(isConnecting)
        #endif
    }

    private var title: LocalizedStringKey {
        if let editing { return "Edit \u{201C}\(editing.name)\u{201D}" }
        return "Connect a Server"
    }

    private var form: some View {
        Form {
            Section {
                TextField("Address", text: $address, prompt: Text(verbatim: "music.example.com"))
                    .textContentType(.URL)
                    .literalEntry(isAddress: true)
                    .focused($focus, equals: .address)
                    #if os(iOS)
                    .submitLabel(.next)
                    .onSubmit { focus = .username }
                    #endif
                TextField("Username", text: $username, prompt: Text("Required"))
                    .textContentType(.username)
                    .literalEntry()
                    .focused($focus, equals: .username)
                    #if os(iOS)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
                    #endif
                SecureField("Password", text: $password, prompt: Text("Required"))
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    #if os(iOS)
                    .submitLabel(.go)
                    .onSubmit(connect)
                    #endif
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.ink(.red))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if isInsecure {
                        Label("This address isn’t encrypted. Use https if your server has it, especially away from home.", systemImage: "lock.open")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    #if os(macOS)
                    Text("Tracks sends a token made from your password, never the password itself, and keeps the password in this Mac’s keychain.")
                    #else
                    Text("Tracks sends a token made from your password, never the password itself, and keeps the password in this iPhone’s keychain.")
                    #endif
                }
                .animation(SettingsMotion.fade, value: problem)
                .animation(SettingsMotion.fade, value: isInsecure)
            }
            Section {
                TextField("Name", text: $name, prompt: Text(defaultName))
                    .titleEntry()
                    .focused($focus, equals: .name)
            } footer: {
                #if os(iOS)
                Text("Works with Navidrome, Gonic, Airsonic, Ampache, LMS and other servers that speak the Subsonic API.")
                #endif
            }
        }
    }

    private var canConnect: Bool {
        SubsonicServer.address(from: address) != nil && !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
    }

    /// The server's host, or "Home Server" until there's an address.
    private var defaultName: String {
        let host = SubsonicServer.address(from: address)?.host() ?? ""
        return host.isEmpty ? String(localized: "Home Server") : host
    }

    /// Plain http to anywhere but the home network.
    private var isInsecure: Bool {
        guard let url = SubsonicServer.address(from: address), url.scheme == "http", let host = url.host() else { return false }
        let local = host.hasSuffix(".local") || host == "localhost" || host.hasPrefix("192.168.") || host.hasPrefix("10.") || host.hasPrefix("172.")
        return !local
    }

    private func fillIn() {
        if let editing {
            name = editing.name
            address = editing.url.absoluteString
            username = editing.username
            focus = .password
        } else {
            focus = .address
        }
    }

    private func connect() {
        guard canConnect, !isConnecting, let url = SubsonicServer.address(from: address) else { return }
        problem = nil
        isConnecting = true
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        var server = editing ?? SubsonicServer(name: "", url: url, username: "")
        server.name = trimmedName.isEmpty ? defaultName : trimmedName
        server.url = url
        server.username = username.trimmingCharacters(in: .whitespaces)
        Task {
            defer { isConnecting = false }
            do {
                try await music.servers.add(server, password: password)
                dismiss()
            } catch let error as SubsonicError {
                problem = MusicServers.describe(error)
            } catch {
                #if os(macOS)
                problem = String(localized: "Couldn’t reach the server. Check the address, and that this Mac can reach it.")
                #else
                problem = String(localized: "Couldn’t reach the server. Check the address, and that this iPhone can reach it.")
                #endif
            }
        }
    }
}
