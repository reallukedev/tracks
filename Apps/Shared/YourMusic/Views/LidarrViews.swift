import SwiftUI
import TracksCore

// MARK: - Settings

/// Lidarr, in Play's settings: connect it, and choose how what Tracks adds is filed.
struct LidarrSettingsLink: View {
    @Environment(Lidarr.self) private var lidarr

    var body: some View {
        Section {
            NavigationLink {
                LidarrSettingsPage()
            } label: {
                LabeledContent {
                    Text(statusLine)
                } label: {
                    Label("Lidarr", systemImage: "tray.and.arrow.down")
                }
            }
        } header: {
            Text("Requests")
        } footer: {
            Text("Connect Lidarr to add artists and ask for albums from anywhere in Tracks. What Lidarr files, your server plays, and Tracks can download.")
        }
    }

    private var statusLine: String {
        switch lidarr.status {
        case .off: String(localized: "Not Connected")
        case .connecting: String(localized: "Connecting…")
        case .connected: String(localized: "Connected")
        case .wrongKey: String(localized: "Key Needed")
        case .failed: String(localized: "Can't Be Reached")
        }
    }
}

struct LidarrSettingsPage: View {
    @Environment(Lidarr.self) private var lidarr
    @State private var editsConnection = false
    @State private var confirmsDisconnect = false

    var body: some View {
        @Bindable var lidarr = lidarr
        Form {
            if !lidarr.isSetUp {
                Section {
                    Button("Connect Lidarr", systemImage: "link") { editsConnection = true }
                } footer: {
                    Text("You'll need Lidarr's address, often ending in :8686, and its API key, from Settings › General in Lidarr.")
                }
            } else {
                Section {
                    LabeledContent("Status", value: statusLine)
                    if let url = lidarr.server?.url {
                        LabeledContent("Address", value: url.absoluteString)
                    }
                    NavigationLink("Activity") { LidarrPage() }
                }

                Section {
                    Picker("Follow", selection: $lidarr.monitor) {
                        Text("All Albums").tag(LidarrAddOptions.Monitor.all)
                        Text("New Albums Only").tag(LidarrAddOptions.Monitor.future)
                        Text("Latest Album").tag(LidarrAddOptions.Monitor.latest)
                        Text("Only Albums I Ask For").tag(LidarrAddOptions.Monitor.none)
                    }
                    Toggle("Search Right Away", isOn: $lidarr.searchesNow)
                } header: {
                    Text("Adding Artists")
                } footer: {
                    Text(lidarr.monitor == .none
                        ? "Artists are added without their albums. Ask for albums one at a time from Tracks."
                        : "What Lidarr follows when you add an artist from Tracks. Asking for one album always gets just that album.")
                }

                if !lidarr.rootFolders.isEmpty || !lidarr.qualityProfiles.isEmpty {
                    Section {
                        if !lidarr.rootFolders.isEmpty {
                            Picker("Folder", selection: Binding(
                                get: { lidarr.rootFolderPath ?? lidarr.rootFolders.first?.path ?? "" },
                                set: { lidarr.rootFolderPath = $0 }
                            )) {
                                ForEach(lidarr.rootFolders) { Text($0.path).tag($0.path) }
                            }
                        }
                        if !lidarr.qualityProfiles.isEmpty {
                            Picker("Quality", selection: Binding(
                                get: { lidarr.qualityProfileID ?? lidarr.qualityProfiles.first?.id ?? 0 },
                                set: { lidarr.qualityProfileID = $0 }
                            )) {
                                ForEach(lidarr.qualityProfiles) { Text($0.name).tag($0.id) }
                            }
                        }
                        if !lidarr.metadataProfiles.isEmpty {
                            Picker("Releases", selection: Binding(
                                get: { lidarr.metadataProfileID ?? lidarr.metadataProfiles.first?.id ?? 0 },
                                set: { lidarr.metadataProfileID = $0 }
                            )) {
                                ForEach(lidarr.metadataProfiles) { Text($0.name).tag($0.id) }
                            }
                        }
                    } header: {
                        Text("Filing")
                    } footer: {
                        Text("Lidarr's own folders and profiles. Choose Lossless in Quality to keep FLAC.")
                    }
                }

                Section {
                    Button("Change Address or Key", systemImage: "key") { editsConnection = true }
                    Button("Disconnect Lidarr", role: .destructive) { confirmsDisconnect = true }
                }
            }
        }
        .navigationTitle("Lidarr")
        .toolbarTitleDisplayMode(.inline)
        .sheet(isPresented: $editsConnection) { LidarrConnectForm() }
        .confirmationDialog("Disconnect Lidarr?", isPresented: $confirmsDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { lidarr.disconnect() }
        } message: {
            Text("Lidarr keeps everything it follows and has. Tracks just stops asking it for more.")
        }
        .task { await lidarr.check() }
    }

    private var statusLine: String {
        switch lidarr.status {
        case .off: String(localized: "Not Connected")
        case .connecting: String(localized: "Connecting…")
        case .connected(let version): String(localized: "Connected · Lidarr \(version)")
        case .wrongKey: String(localized: "The API key was refused")
        case .failed(let reason): reason
        }
    }
}

/// Lidarr's address and API key, checked before they're kept.
struct LidarrConnectForm: View {
    @Environment(Lidarr.self) private var lidarr
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var key = ""
    @State private var isConnecting = false
    @State private var problem: String?

    var body: some View {
        #if os(macOS)
        // A Mac sheet: the title in the content, the fields, and Cancel and Connect at the foot.
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect Lidarr")
                    .font(.title2.bold())
                Text("Tracks asks Lidarr for albums and adds artists to it. The key stays in this Mac's Keychain, and goes only to your Lidarr.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            Form {
                TextField("Address", text: $address, prompt: Text(verbatim: "192.168.1.20:8686"))
                    .textContentType(.URL)
                    .literalEntry(isAddress: true)
                SecureField("API Key", text: $key, prompt: Text("From Settings › General in Lidarr"))
                    .literalEntry()
                    .onSubmit(connect)
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.columns)
            .padding(.horizontal, 20)
            HStack(spacing: 8) {
                if isConnecting {
                    ProgressView().controlSize(.small)
                    Text("Connecting…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect", action: connect)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConnect || isConnecting)
            }
            .padding(20)
        }
        .frame(width: 440)
        .disabled(isConnecting)
        .onAppear(perform: fill)
        #else
        NavigationStack {
            Form {
                Section {
                    TextField("Address", text: $address, prompt: Text(verbatim: "192.168.1.20:8686"))
                        .textContentType(.URL)
                        .literalEntry(isAddress: true)
                    SecureField("API Key", text: $key)
                        .literalEntry()
                        .onSubmit(connect)
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let problem {
                            Label(problem, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        }
                        #if os(macOS)
                        Text("Find the API key in Lidarr under Settings › General. It's kept in this Mac's keychain, and sent only to your Lidarr.")
                        #else
                        Text("Find the API key in Lidarr under Settings › General. It's kept in this iPhone's Keychain, and sent only to your Lidarr.")
                        #endif
                    }
                }
            }
            .navigationTitle("Connect Lidarr")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isConnecting {
                        ProgressView()
                    } else {
                        Button("Connect", systemImage: "checkmark", action: connect)
                            .disabled(!canConnect)
                    }
                }
            }
            .disabled(isConnecting)
            .onAppear(perform: fill)
        }
        .interactiveDismissDisabled(isConnecting)
        #endif
    }

    private var canConnect: Bool {
        LidarrServer.address(from: address) != nil && !key.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func fill() {
        if let url = lidarr.server?.url { address = url.absoluteString }
    }

    private func connect() {
        guard canConnect, let url = LidarrServer.address(from: address) else { return }
        problem = nil
        isConnecting = true
        Task {
            defer { isConnecting = false }
            do {
                try await lidarr.connect(to: LidarrServer(url: url), apiKey: key.trimmingCharacters(in: .whitespaces))
                dismiss()
            } catch let error as LidarrError {
                problem = Lidarr.describe(error)
            } catch {
                problem = String(localized: "Couldn't reach Lidarr. Check the address and port, and that this device can reach it.")
            }
        }
    }
}

// MARK: - Activity

/// What Lidarr is doing: downloading, wanting, expecting, and who it follows. Tables on the
/// Mac, chosen in the toolbar; lists under a segmented control on iPhone.
struct LidarrPage: View {
    @Environment(Lidarr.self) private var lidarr
    @Environment(PlayerModel.self) private var player
    @SceneStorage("lidarrSection") private var section = Section.downloading
    @State private var addsArtist = false

    enum Section: String, CaseIterable, Identifiable {
        case downloading, wanted, upcoming, artists
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .downloading: "Downloading"
            case .wanted: "Wanted"
            case .upcoming: "Coming Soon"
            case .artists: "Artists"
            }
        }
    }

    var body: some View {
        content
            .overlay {
                if isEmpty {
                    emptyState
                }
            }
            .navigationTitle("Lidarr")
            #if os(macOS)
            .navigationSubtitle(subtitle)
            #else
            .toolbarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(macOS)
                ToolbarItem(placement: .principal) {
                    Picker("Show", selection: $section) {
                        ForEach(Section.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await refresh() }
                    }
                    // ⌘R is View > Refresh, which this page answers through `refreshCommand()`.
                    .help("Refresh (⌘R)")
                }
                #endif
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Artist", systemImage: "plus") { addsArtist = true }
                        .disabled(!lidarr.isConnected)
                        .help("Add an Artist to Lidarr")
                }
            }
            .sheet(isPresented: $addsArtist) { LidarrAddArtistSheet() }
            .task { await refresh() }
            .refreshCommand()
            .refreshable { await refresh() }
    }

    private func refresh() async {
        await lidarr.refreshActivity()
        await lidarr.refreshArtists(force: true)
    }

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        switch section {
        case .downloading: LidarrQueueTable(items: lidarr.queue)
        case .wanted: LidarrAlbumTable(albums: lidarr.missing, kind: .wanted)
        case .upcoming: LidarrAlbumTable(albums: lidarr.upcoming, kind: .upcoming)
        case .artists: LidarrArtistTable(artists: lidarr.artists)
        }
        #else
        List {
            switch section {
            case .downloading:
                ForEach(lidarr.queue) { item in
                    LidarrQueueRow(item: item)
                }
            case .wanted:
                ForEach(lidarr.missing) { album in
                    LidarrAlbumRow(album: album, showsArtist: true) {
                        Button("Search", systemImage: "magnifyingglass") {
                            Task { player.confirm(await lidarr.search(albums: [album.id])) }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.circle)
                        .accessibilityLabel("Search for \(album.title)")
                    }
                }
            case .upcoming:
                ForEach(lidarr.upcoming) { album in
                    LidarrAlbumRow(album: album, showsArtist: true) {
                        if let date = album.releaseDate {
                            Text(date.formatted(.dateTime.month(.abbreviated).day()))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                    }
                }
            case .artists:
                ForEach(lidarr.artists) { artist in
                    if let id = artist.id {
                        NavigationLink(value: PlayRoute.lidarrArtist(id)) {
                            LidarrArtistRow(artist: artist)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .safeAreaBar(edge: .top) {
            Picker("Show", selection: $section) {
                ForEach(Section.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, PlayMetrics.margin)
            .padding(.vertical, 8)
        }
        #endif
    }

    /// "3 downloading", in the window's subtitle on the Mac.
    private var subtitle: String {
        switch section {
        case .downloading: String(AttributedString(localized: "^[\(lidarr.queue.count) album](inflect: true) downloading").characters)
        case .wanted: String(AttributedString(localized: "^[\(lidarr.missing.count) album](inflect: true) wanted").characters)
        case .upcoming: String(AttributedString(localized: "^[\(lidarr.upcoming.count) album](inflect: true) coming").characters)
        case .artists: String(AttributedString(localized: "^[\(lidarr.artists.count) artist](inflect: true) followed").characters)
        }
    }

    private var isEmpty: Bool {
        switch section {
        case .downloading: lidarr.queue.isEmpty
        case .wanted: lidarr.missing.isEmpty
        case .upcoming: lidarr.upcoming.isEmpty
        case .artists: lidarr.artists.isEmpty
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: emptySymbol)
        } description: {
            Text(emptyMessage)
        } actions: {
            if section == .artists, lidarr.isConnected {
                Button("Add Artist") { addsArtist = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var emptyTitle: LocalizedStringKey {
        switch section {
        case .downloading: "Nothing Downloading"
        case .wanted: "Nothing Wanted"
        case .upcoming: "Nothing Coming Soon"
        case .artists: "No Artists Yet"
        }
    }

    private var emptySymbol: String {
        switch section {
        case .downloading: "arrow.down.circle"
        case .wanted: "magnifyingglass"
        case .upcoming: "calendar"
        case .artists: "music.microphone"
        }
    }

    private var emptyMessage: LocalizedStringKey {
        switch section {
        case .downloading: "Albums Lidarr is fetching show here, until they're filed."
        case .wanted: "Albums Lidarr follows but doesn't have yet show here."
        case .upcoming: "New albums from the artists Lidarr follows show here before they're out."
        case .artists: "Add artists here, or from any artist in Tracks."
        }
    }
}

#if os(macOS)
/// What Lidarr is fetching, as a table: the album, who it's by, how far along, and what's
/// happening to it.
private struct LidarrQueueTable: View {
    let items: [LidarrQueueItem]
    @State private var selection: Set<LidarrQueueItem.ID> = []

    var body: some View {
        Table(items, selection: $selection) {
            TableColumn("Album") { item in
                LidarrTableTitle(url: item.album?.coverURL, title: item.album?.title ?? item.title ?? "")
            }
            .width(min: 180, ideal: 280)
            TableColumn("Artist") { item in
                Text(item.artist?.artistName ?? "").lineLimit(1)
            }
            .width(min: 100, ideal: 170)
            TableColumn("Progress") { item in
                ProgressView(value: item.progress)
                    .tint(item.errorMessage == nil ? .accentColor : .red)
                    .controlSize(.small)
                    .accessibilityValue(Text(item.progress, format: .percent.precision(.fractionLength(0))))
            }
            .width(min: 80, ideal: 120)
            TableColumn("Status") { item in
                Text(LidarrQueueRow.statusLine(of: item))
                    .foregroundStyle(item.errorMessage == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    .lineLimit(1)
                    .help(LidarrQueueRow.statusLine(of: item))
            }
            .width(min: 120, ideal: 220)
        }
    }
}

/// Albums Lidarr wants or expects, as a table. Wanted albums search on a double-click or
/// Return; the menu offers the same for several at once.
private struct LidarrAlbumTable: View {
    enum Kind { case wanted, upcoming }

    let albums: [LidarrAlbum]
    let kind: Kind
    @Environment(Lidarr.self) private var lidarr
    @Environment(PlayerModel.self) private var player
    @State private var selection: Set<LidarrAlbum.ID> = []
    @State private var sortOrder = [KeyPathComparator(\LidarrAlbum.releaseSortDate, order: .reverse)]

    var body: some View {
        Table(albums.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Album", value: \.title) { album in
                LidarrTableTitle(url: album.coverURL, title: album.title)
            }
            .width(min: 180, ideal: 280)
            TableColumn("Artist", value: \.artistSortName) { album in
                Text(album.artist?.artistName ?? "").lineLimit(1)
            }
            .width(min: 100, ideal: 170)
            TableColumn("Type", value: \.typeSortName) { album in
                Text(album.albumType ?? "").foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 60, ideal: 80, max: 120)
            TableColumn(kind == .upcoming ? "Out" : "Released", value: \.releaseSortDate) { album in
                Text(album.releaseDate.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "")
                    .monospacedDigit()
                    .foregroundStyle(kind == .upcoming ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .width(min: 90, ideal: 110, max: 140)
        }
        .contextMenu(forSelectionType: LidarrAlbum.ID.self) { ids in
            if kind == .wanted, !ids.isEmpty {
                Button(ids.count == 1 ? "Search" : "Search for ^[\(ids.count) Album](inflect: true)", systemImage: "magnifyingglass") {
                    search(ids)
                }
            }
        } primaryAction: { ids in
            if kind == .wanted { search(ids) }
        }
    }

    private func search(_ ids: Set<LidarrAlbum.ID>) {
        Task { player.confirm(await lidarr.search(albums: Array(ids))) }
    }
}

/// The artists Lidarr follows, as a table: double-click or Return opens one.
private struct LidarrArtistTable: View {
    let artists: [LidarrArtist]
    @Environment(\.openPlayRoute) private var openPlayRoute
    @State private var selection: Set<LidarrArtist.ID> = []
    @State private var sortOrder = [KeyPathComparator(\LidarrArtist.artistName)]

    var body: some View {
        Table(artists.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Artist", value: \.artistName) { artist in
                HStack(spacing: 8) {
                    LidarrCover(url: artist.pictureURL, seed: artist.artistName, size: 22, isCircle: true)
                    Text(artist.artistName).lineLimit(1)
                }
            }
            .width(min: 180, ideal: 300)
            TableColumn("Songs", value: \.fileCount) { artist in
                Text(LidarrArtistRow.songsLine(of: artist) ?? "")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 120)
            TableColumn("Genre") { artist in
                Text(artist.genres?.first ?? "").foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 140)
        }
        .contextMenu(forSelectionType: LidarrArtist.ID.self) { ids in
            if ids.count == 1, let id = ids.first.flatMap(\.self) {
                Button("Open", systemImage: "arrow.forward.circle") { openPlayRoute(.lidarrArtist(id)) }
            }
        } primaryAction: { ids in
            if let id = ids.first.flatMap(\.self) { openPlayRoute(.lidarrArtist(id)) }
        }
    }
}

/// A table's first column: a small cover and a name.
private struct LidarrTableTitle: View {
    let url: URL?
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            LidarrCover(url: url, seed: title, size: 22)
            Text(title).lineLimit(1)
        }
    }
}

extension LidarrAlbum {
    /// Sort keys for a table: a missing value goes last rather than failing to compare.
    nonisolated var releaseSortDate: Date { releaseDate ?? .distantPast }
    nonisolated var artistSortName: String { artist?.artistName ?? "" }
    nonisolated var typeSortName: String { albumType ?? "" }
}

extension LidarrArtist {
    nonisolated var fileCount: Int { statistics?.trackFileCount ?? 0 }
}
#endif

private struct LidarrQueueRow: View {
    let item: LidarrQueueItem

    var body: some View {
        HStack(spacing: 12) {
            LidarrCover(url: item.album?.coverURL, seed: item.album?.title ?? item.title ?? "", size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.album?.title ?? item.title ?? "")
                    .lineLimit(1)
                if let artist = item.artist?.artistName {
                    Text(artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                ProgressView(value: item.progress)
                    .tint(item.errorMessage == nil ? .accentColor : .red)
                Text(Self.statusLine(of: item))
                    .font(.caption)
                    .foregroundStyle(item.errorMessage == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    static func statusLine(of item: LidarrQueueItem) -> String {
        if let error = item.errorMessage, !error.isEmpty { return error }
        switch item.trackedDownloadState {
        case "importPending": return String(localized: "Downloaded, waiting to be filed")
        case "importing": return String(localized: "Filing")
        case "imported": return String(localized: "Filed")
        case "failedPending": return String(localized: "Couldn't be filed")
        default:
            if let left = item.timeleft, let seconds = Self.seconds(left), seconds > 0 {
                return String(localized: "\(Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))) left")
            }
            return item.status == "queued" ? String(localized: "Queued") : String(localized: "Downloading")
        }
    }

    /// "01:02:10" as seconds.
    static func seconds(_ text: String) -> Int? {
        let parts = text.split(separator: ":").compactMap { Int($0.split(separator: ".").last ?? $0) }
        guard parts.count == 3 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }
}

/// An album in Lidarr as a row: its cover, name, artist and when it's out, and what can be
/// done with it.
private struct LidarrAlbumRow<Trailing: View>: View {
    let album: LidarrAlbum
    var showsArtist = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            LidarrCover(url: album.coverURL, seed: album.title, size: Self.coverSide)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title).lineLimit(1)
                if showsArtist, let artist = album.artist?.artistName {
                    Text(artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 4)
    }

    private var detail: String {
        [album.albumType, album.releaseDate.map { $0.formatted(.dateTime.year()) }].compactMap(\.self).joined(separator: " · ")
    }

    #if os(macOS)
    private static var coverSide: CGFloat { 40 }
    #else
    private static var coverSide: CGFloat { 52 }
    #endif
}

private struct LidarrArtistRow: View {
    let artist: LidarrArtist

    var body: some View {
        HStack(spacing: 12) {
            LidarrCover(url: artist.pictureURL, seed: artist.artistName, size: 48, isCircle: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(artist.artistName).lineLimit(1)
                if let songs = Self.songsLine(of: artist) {
                    Text(songs)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// "12 of 40 songs": what Lidarr has of what it knows of theirs.
    static func songsLine(of artist: LidarrArtist) -> String? {
        guard let statistics = artist.statistics, let total = statistics.totalTrackCount ?? statistics.trackCount, total > 0 else { return nil }
        return String(localized: "\(statistics.trackFileCount ?? 0) of \(total) songs")
    }
}

/// A cover from outside Lidarr, or a generated one.
struct LidarrCover: View {
    let url: URL?
    let seed: String
    let size: CGFloat
    var isCircle = false

    var body: some View {
        ArtworkView(url: url?.absoluteString, seed: seed, size: size, isCircle: isCircle, maximumCornerRadius: CoverImage.maximumRadius)
    }
}

// MARK: - An artist

/// An artist Lidarr follows, on the artist page every source shares: every album of theirs it
/// knows, what it has, and a way to get the rest, or download what it has.
struct LidarrArtistPage: View {
    let artistID: Int
    @Environment(Lidarr.self) private var lidarr
    @Environment(YourMusic.self) private var music
    @Environment(PlayerModel.self) private var player
    @State private var albums: [LidarrAlbum] = []
    @State private var hasLoaded = false
    @State private var busy: Set<Int> = []

    var body: some View {
        let artist = lidarr.artists.first { $0.id == artistID }
        let name = artist?.artistName ?? String(localized: "Artist")
        ArtistScaffold(name: name, picture: artist?.pictureURL.map { .url($0.absoluteString, seed: name) }) {
            Button("Search for Missing", systemImage: "magnifyingglass") { searchMissing() }
        } sections: {
            if let overview = artist?.overview, !overview.isEmpty {
                LidarrOverview(text: overview)
            }
            VStack(alignment: .leading, spacing: 8) {
                ArtistSectionTitle(title: String(localized: "Albums")) {
                    if let songs = artist.flatMap(LidarrArtistRow.songsLine) {
                        Text(songs)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                if !hasLoaded {
                    LoadingRows(count: 5)
                        .padding(.horizontal, PlayMetrics.margin)
                } else {
                    VStack(spacing: 0) {
                        ForEach(albums) { album in
                            LidarrAlbumRow(album: album) {
                                action(for: album, artist: name)
                            }
                            if album.id != albums.last?.id {
                                Divider().padding(.leading, 64)
                            }
                        }
                    }
                    .padding(.horizontal, PlayMetrics.margin)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Search for Missing", systemImage: "magnifyingglass", action: searchMissing)
                    .help("Search for Missing Albums")
            }
        }
        .task { await load(force: false) }
        .refreshCommand()
        .refreshable { await load(force: true) }
    }

    private func searchMissing() {
        Task { player.confirm(await lidarr.searchMissing(of: artistID)) }
    }

    @ViewBuilder
    private func action(for album: LidarrAlbum, artist: String) -> some View {
        if busy.contains(album.id) {
            ProgressView().controlSize(.small).frame(width: 44, height: 32)
        } else if album.isComplete {
            // In the collection: your server has it, or will once it syncs.
            Button("Download", systemImage: "arrow.down.circle") {
                run(album) { await music.downloadFromCollection(album: album.title, by: artist) }
            }
            .labelStyle(.iconOnly)
            .font(.title3)
            .buttonStyle(.borderless)
            .help("Download \(album.title)")
            .accessibilityLabel("Download \(album.title)")
        } else if album.monitored == true {
            Button("Search") {
                run(album) { await lidarr.search(albums: [album.id]) }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(rowControlSize)
            .help("Ask Lidarr to Search for \(album.title)")
        } else {
            Button("Get") {
                run(album) { await lidarr.request(album: album.title, by: artist) }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(rowControlSize)
            .help("Get \(album.title) with Lidarr")
        }
    }

    /// Small on the Mac, as its lists are dense. A finger needs the regular size.
    private var rowControlSize: ControlSize {
        #if os(iOS)
        .regular
        #else
        .small
        #endif
    }

    private func run(_ album: LidarrAlbum, _ work: @escaping () async -> String) {
        busy.insert(album.id)
        Task {
            let message = await work()
            busy.remove(album.id)
            player.confirm(message)
            await load(force: true)
        }
    }

    private func load(force: Bool) async {
        albums = await lidarr.albums(of: artistID, force: force)
            .sorted { ($0.releaseDate ?? .distantPast) > ($1.releaseDate ?? .distantPast) }
        hasLoaded = true
    }
}

/// Lidarr's words on an artist: four lines, and the rest on More.
private struct LidarrOverview: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(isExpanded ? nil : 4)
                .frame(maxWidth: 680, alignment: .leading)
            if !isExpanded {
                Button("More") { isExpanded = true }
                    .buttonStyle(.borderless)
                    .font(.callout.weight(.semibold))
            }
        }
        .padding(.horizontal, PlayMetrics.margin)
    }
}

// MARK: - Adding

/// Finding an artist in Lidarr's search and adding them, as many as you like before Done.
struct LidarrAddArtistSheet: View {
    @Environment(Lidarr.self) private var lidarr
    @Environment(PlayerModel.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [LidarrArtist] = []
    @State private var isSearching = false
    @State private var adding: String?
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        #if os(macOS)
        // A Mac sheet: the title in the content, a plain search field, the results, and Done.
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add an Artist")
                    .font(.title2.bold())
                Text("Lidarr follows who you add, and files their albums as you've chosen in Settings.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)
            TextField("Artist", text: $query, prompt: Text("Search for an Artist"))
                .textFieldStyle(.roundedBorder)
                .focused($isFieldFocused)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            Group {
                if results.isEmpty {
                    placeholder
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    List(results, id: \.foreignArtistId) { artist in
                        row(artist)
                            .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                    .frame(height: 320)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
            .background {
                // Escape closes too.
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .hidden()
            }
        }
        .frame(width: 460)
        .defaultFocus($isFieldFocused, true)
        .task(id: query) { await search() }
        #else
        NavigationStack {
            List(results, id: \.foreignArtistId) { artist in
                row(artist)
            }
            .listStyle(.plain)
            .overlay {
                if results.isEmpty, !query.isEmpty, !isSearching {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, placement: .pageSearch(), prompt: "Artist")
            .task(id: query) { await search() }
            .navigationTitle("Add an Artist")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        #endif
    }

    /// What the results area says before there are any.
    @ViewBuilder
    private var placeholder: some View {
        if isSearching {
            ProgressView().controlSize(.small)
        } else if query.trimmingCharacters(in: .whitespaces).count >= 2 {
            ContentUnavailableView.search(text: query)
        } else {
            Text("Type at least two letters of their name.")
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ artist: LidarrArtist) -> some View {
        HStack(spacing: 12) {
            LidarrCover(url: artist.pictureURL, seed: artist.artistName, size: Self.pictureSide, isCircle: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(artist.artistName).lineLimit(1)
                if let detail = artist.disambiguation ?? artist.genres?.first {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if adding == artist.foreignArtistId {
                ProgressView().controlSize(.small)
            } else if lidarr.follows(artist) {
                Label("Following", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .help("Lidarr Already Follows \(artist.artistName)")
                    .accessibilityLabel("Already Following")
            } else {
                Button("Add") { add(artist) }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .help("Add \(artist.artistName) to Lidarr")
            }
        }
        .padding(.vertical, 2)
    }

    #if os(macOS)
    private static var pictureSide: CGFloat { 36 }
    #else
    private static var pictureSide: CGFloat { 48 }
    #endif

    private func search() async {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard term.count >= 2, let client = lidarr.client else {
            results = []
            isSearching = false
            return
        }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        isSearching = true
        results = (try? await client.lookUpArtists(term)) ?? []
        isSearching = false
    }

    private func add(_ artist: LidarrArtist) {
        adding = artist.foreignArtistId
        Task {
            let message = await lidarr.add(artist)
            adding = nil
            player.confirm(message)
        }
    }
}

// MARK: - From anywhere

/// "Add to Lidarr", for an artist on any page.
struct AddToLidarrButton: View {
    let artistName: String
    @Environment(Lidarr.self) private var lidarr
    @Environment(PlayerModel.self) private var player

    var body: some View {
        if lidarr.isSetUp {
            if lidarr.artist(named: artistName) != nil {
                Button("Lidarr Follows \(artistName)", systemImage: "checkmark.circle") {}
                    .disabled(true)
            } else {
                Button("Add to Lidarr", systemImage: "tray.and.arrow.down") {
                    Task { player.confirm(await lidarr.follow(artistNamed: artistName)) }
                }
            }
        }
    }
}

/// "Get with Lidarr", for an album on any page.
struct GetWithLidarrButton: View {
    let album: String
    let artist: String
    @Environment(Lidarr.self) private var lidarr
    @Environment(PlayerModel.self) private var player

    var body: some View {
        if lidarr.isSetUp {
            Button("Get with Lidarr", systemImage: "tray.and.arrow.down") {
                Task { player.confirm(await lidarr.request(album: album, by: artist)) }
            }
        }
    }
}
