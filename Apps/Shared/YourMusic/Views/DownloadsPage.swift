import SwiftUI
import TracksCore

/// Everything downloaded to this iPhone, to look after: the room it takes against what's left,
/// what you play of it, what's coming down or couldn't, and the songs themselves, by album or
/// one by one, in the order you like. What you haven't played in months can go in one go.
struct DownloadsPage: View {
    var body: some View {
        #if os(macOS)
        LibraryDownloadsPage()
        #else
        DownloadsList()
        #endif
    }
}

#if os(iOS)
private struct DownloadsList: View {
    @Environment(YourMusic.self) private var music
    @Environment(PlayFeed.self) private var feed
    @Environment(PlayerModel.self) private var player
    @AppStorage(Downloads.cellularKey) private var allowsCellular = true
    @AppStorage(AutomaticDownloads.storageKey) private var automaticDownloads = true
    @AppStorage(StreamQuality.downloadKey) private var downloadQuality = StreamQuality.original
    @AppStorage("downloadsOrder") private var order = DownloadReport.Order.recent
    @AppStorage("downloadsShowsSongs") private var showsSongs = false
    @State private var confirmsRemoveAll = false
    @State private var confirmsFreeingUp = false
    /// The room left on this iPhone, read when the page opens and after anything's removed.
    @State private var freeBytes: Int64?

    var body: some View {
        let downloads = music.downloads
        // Each song as its file is, so a smaller copy isn't counted as lossless.
        let songs = downloads.items.values.map { DownloadedSong(track: $0.keptTrack, bytes: $0.bytes, downloadedAt: $0.downloadedAt) }
        let stats = DownloadReport.stats(songs, facts: feed.facts)
        let unplayed = DownloadReport.unplayed(songs, facts: feed.facts)
        let active = downloads.downloading
        let failed = downloads.failures.keys.sorted().compactMap { id in music.index.track(id: id).map { ($0, downloads.failures[id] ?? "") } }
        List {
            // What's under way first: it's what you come to check. Its own view, so each step
            // of a download redraws only its row, not the whole page.
            if !active.isEmpty {
                DownloadingSection(ids: active.sorted())
            }

            if !failed.isEmpty {
                Section {
                    ForEach(failed, id: \.0.id) { track, reason in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title).lineLimit(1)
                            Text(reason).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Button("Try Again", systemImage: "arrow.clockwise") { downloads.retryFailed() }
                } header: {
                    Text("Couldn't Download")
                }
            }

            // The music, as the library's pages have it: Play and Shuffle, then the albums or
            // songs in the order chosen.
            if !songs.isEmpty {
                let sorted = DownloadReport.sorted(songs, by: order, facts: feed.facts)
                Section {
                    let context = PlayContext(kind: .songs, title: String(localized: "Downloads"))
                    let all = sorted.map(\.track)
                    LibraryPlayButtons {
                        player.play(.local(all), from: context)
                    } shuffle: {
                        player.play(.local(all), from: context, shuffled: true)
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                }

                Section {
                    if showsSongs {
                        ForEach(sorted) { song in
                            songRow(song, in: sorted.map(\.track))
                        }
                    } else {
                        ForEach(albums(of: songs)) { album in
                            albumRow(album)
                        }
                    }
                } header: {
                    HStack {
                        Picker("Show", selection: $showsSongs) {
                            Text("Albums").tag(false)
                            Text("Songs").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        Spacer()
                        Menu {
                            Picker("Sort By", selection: $order) {
                                ForEach(DownloadReport.Order.allCases) { order in
                                    Text(title(of: order)).tag(order)
                                }
                            }
                        } label: {
                            Label("Sort", systemImage: "arrow.up.arrow.down")
                                .labelStyle(.iconOnly)
                                .frame(minWidth: 44, minHeight: 32)
                        }
                        .accessibilityLabel("Sort By")
                    }
                    .textCase(nil)
                }
            }

            // Looking after the room they take, below the music.
            if !songs.isEmpty || music.fileBytes > 0 {
                Section {
                    StorageBar(downloads: stats.bytes, files: music.fileBytes, free: freeBytes)
                        .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                    if !songs.isEmpty {
                        statsGrid(stats)
                            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                    }
                    if !unplayed.isEmpty {
                        Button {
                            confirmsFreeingUp = true
                        } label: {
                            LabeledContent {
                                Text(LocalFormat.bytes(unplayed.map(\.bytes).reduce(0, +)))
                            } label: {
                                Label("Free Up Space", systemImage: "leaf")
                            }
                        }
                    }
                } header: {
                    Text("Storage")
                } footer: {
                    if !unplayed.isEmpty {
                        Text("Free Up Space removes the ^[\(unplayed.count) song](inflect: true) you haven't played in three months. They stay on your servers, to download again whenever you like.")
                    }
                }
            }

            Section {
                Toggle("Automatic Downloads", isOn: $automaticDownloads)
                Toggle("Download over Cellular", isOn: $allowsCellular)
                StreamQualityPicker(title: "Download Quality", selection: $downloadQuality)
            } footer: {
                let quality = AudioQualityWords.downloadDetail(downloadQuality.maxBitRate)
                Text(allowsCellular
                    ? "With Automatic Downloads, songs you play or add from your servers come down to this iPhone. \(quality) They don’t count against iCloud backup."
                    : "Downloads wait for Wi-Fi, and start by themselves when you’re back on it. \(quality)")
                    .contentTransition(.opacity)
            }

            if !songs.isEmpty {
                Section {
                    Button("Remove All Downloads", role: .destructive) { confirmsRemoveAll = true }
                }
            }
        }
        .animation(.snappy, value: showsSongs)
        .animation(.snappy, value: order)
        .overlay {
            if songs.isEmpty, active.isEmpty, failed.isEmpty {
                ContentUnavailableView(
                    "Nothing Downloaded",
                    systemImage: "arrow.down.circle",
                    description: Text(automaticDownloads
                        ? "Songs you play from your servers download here by themselves, to play anywhere, even with no connection."
                        : "Download an album or song from its menu to play it anywhere, even with no connection.")
                )
            }
        }
        .navigationTitle("Downloads")
        .onChange(of: allowsCellular) { music.downloads.cellularSettingChanged() }
        .task(id: downloads.items.count) { freeBytes = await Self.freeSpace() }
        .confirmationDialog("Remove All Downloads?", isPresented: $confirmsRemoveAll, titleVisibility: .visible) {
            Button("Remove All", role: .destructive) { downloads.removeAll() }
        } message: {
            Text("They stay on your servers, to download again whenever you like.")
        }
        .confirmationDialog("Free Up \(LocalFormat.bytes(unplayed.map(\.bytes).reduce(0, +)))?", isPresented: $confirmsFreeingUp, titleVisibility: .visible) {
            Button("Remove ^[\(unplayed.count) Song](inflect: true)", role: .destructive) {
                downloads.remove(Set(unplayed.map(\.id)))
            }
        } message: {
            Text("They stay on your servers, to download again whenever you like.")
        }
    }

    // MARK: Parts

    private func statsGrid(_ stats: DownloadReport.Stats) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
            GridRow {
                stat(stats.songs.formatted(), String(localized: "Songs"))
                stat(stats.albums.formatted(), String(localized: "Albums"))
                stat(stats.artists.formatted(), String(localized: "Artists"))
            }
            GridRow {
                stat(Duration.seconds(stats.duration).formatted(.units(allowed: [.hours, .minutes], width: .narrow, maximumUnitCount: 2)), String(localized: "To Listen To"))
                stat(stats.losslessShare.formatted(.percent.precision(.fractionLength(0))), String(localized: "Lossless"))
                stat(stats.neverPlayed.formatted(), String(localized: "Never Played"))
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func songRow(_ song: DownloadedSong, in queue: [LocalTrack]) -> some View {
        Button {
            player.play(.local(queue, startingAt: queue.firstIndex(of: song.track) ?? 0), from: .songs(String(localized: "Downloads")))
        } label: {
            HStack(spacing: 8) {
                LocalTrackRow(track: song.track, isCurrent: player.current?.local?.id == song.track.id)
                // A smaller copy says so beside its size: "MP3 · 128 kbps · 3.1 MB".
                Text(sizeLine(song))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .buttonStyle(.plain)
        .swipeActions {
            Button("Remove", systemImage: "trash", role: .destructive) { music.downloads.remove([song.id]) }
        }
        .contextMenu { LocalTrackMenu(track: song.track) }
    }

    /// The room a song takes, after its format when it's a smaller copy than the original.
    private func sizeLine(_ song: DownloadedSong) -> String {
        let size = LocalFormat.bytes(song.bytes)
        guard let item = music.downloads.items[song.id], item.isSmallerCopy,
              let quality = music.downloads.playback(for: song.id).flatMap(AudioQuality.init)
        else { return size }
        return "\(quality.label) · \(size)"
    }

    private func albumRow(_ album: LocalAlbum) -> some View {
        NavigationLink(value: PlayRoute.localAlbum(album.id)) {
            HStack(spacing: 12) {
                LocalCover(artwork: album.artwork, seed: album.title, size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.displayTitle).lineLimit(1)
                    Text(album.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    Text("^[\(album.tracks.count) song](inflect: true) · \(LocalFormat.bytes(bytes(of: album)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            }
            .accessibilityElement(children: .combine)
        }
        .navigationLinkIndicatorVisibility(.hidden)
        .libraryRowInsets()
        .swipeActions {
            Button("Remove", systemImage: "trash", role: .destructive) {
                music.downloads.remove(Set(album.tracks.map(\.id)))
            }
        }
        .contextMenu { LocalAlbumMenu(album: album) }
    }

    /// Albums of what's downloaded, in the order chosen: by when their last song came down,
    /// by name, by artist, by room taken, or least played first.
    private func albums(of songs: [DownloadedSong]) -> [LocalAlbum] {
        let albums = LocalLibraryIndex(tracks: songs.map(\.track)).albums
        let when = Dictionary(grouping: songs, by: \.track.albumKey).mapValues { $0.map(\.downloadedAt).max() ?? .distantPast }
        let plays = { (album: LocalAlbum) in album.tracks.map { feed.facts[$0.identity]?.plays ?? 0 }.reduce(0, +) }
        switch order {
        case .recent: return albums.sorted { (when[$0.id] ?? .distantPast) > (when[$1.id] ?? .distantPast) }
        case .title: return albums
        case .artist: return albums.sorted { $0.artist.localizedStandardCompare($1.artist) == .orderedAscending }
        case .size: return albums.sorted { bytes(of: $0) > bytes(of: $1) }
        case .leastPlayed: return albums.sorted { plays($0) < plays($1) }
        }
    }

    private func bytes(of album: LocalAlbum) -> Int64 {
        album.tracks.compactMap { music.downloads.items[$0.id]?.bytes }.reduce(0, +)
    }

    private func title(of order: DownloadReport.Order) -> LocalizedStringKey {
        switch order {
        case .recent: "Recently Downloaded"
        case .title: "Title"
        case .artist: "Artist"
        case .size: "Size"
        case .leastPlayed: "Least Played"
        }
    }

    /// The room left on this iPhone for things people keep, as Settings counts it.
    @concurrent
    private static func freeSpace() async -> Int64? {
        let values = try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

/// The songs coming down, each with how far along it is.
private struct DownloadingSection: View {
    let ids: [String]
    @Environment(YourMusic.self) private var music

    var body: some View {
        let downloads = music.downloads
        let active = ids.compactMap { id in music.index.track(id: id).map { ($0, downloads.progress[id] ?? 0) } }
        Section("Downloading") {
            ForEach(active, id: \.0.id) { track, progress in
                HStack(spacing: 12) {
                    LocalCover(artwork: track.artwork, seed: track.album ?? track.title, size: 44)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(track.title).lineLimit(1)
                        Group {
                            if downloads.sizeUnknown.contains(track.id) {
                                ProgressView()
                                    .progressViewStyle(.linear)
                            } else {
                                ProgressView(value: progress)
                            }
                        }
                        .tint(.accentColor)
                    }
                }
                .accessibilityElement(children: .combine)
                .swipeActions {
                    Button("Stop", systemImage: "xmark", role: .destructive) { downloads.cancel([track.id]) }
                }
            }
            let waiting = active.filter { downloads.isWaitingForWiFi($0.0.id, onCellular: music.network.isExpensive) }.count
            if waiting > 0 {
                Label("^[\(waiting) song](inflect: true) waiting for Wi-Fi", systemImage: "wifi")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
#endif

/// Room on this iPhone at a glance: downloads, songs you imported, and what's left, as a bar
/// in the style of Settings' storage page.
struct StorageBar: View {
    let downloads: Int64
    let files: Int64
    let free: Int64?

    var body: some View {
        let total = Double(max(1, downloads + files + (free ?? 0)))
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    Rectangle().fill(Color.accentColor)
                        .frame(width: max(downloads > 0 ? 3 : 0, proxy.size.width * Double(downloads) / total))
                    Rectangle().fill(Color.teal)
                        .frame(width: max(files > 0 ? 3 : 0, proxy.size.width * Double(files) / total))
                    Rectangle().fill(Color(.tertiarySystemFill))
                }
            }
            .frame(height: 10)
            .clipShape(.capsule)
            .accessibilityHidden(true)
            HStack(spacing: 14) {
                legend(color: .accentColor, title: "Downloads", bytes: downloads)
                if files > 0 { legend(color: .teal, title: "Imported", bytes: files) }
                if let free { legend(color: Color(.tertiarySystemFill), title: "Free", bytes: free) }
            }
        }
    }

    private func legend(color: Color, title: LocalizedStringKey, bytes: Int64) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(title).foregroundStyle(.secondary)
            Text(LocalFormat.bytes(bytes)).monospacedDigit()
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}

/// Shuffles every song on this iPhone: what's downloaded, and your own files.
struct ShuffleDownloadsButton: View {
    @Environment(YourMusic.self) private var music
    @Environment(PlayerModel.self) private var player

    var body: some View {
        let songs = music.tracks(for: .downloaded).filter(music.isPlayable)
        Button("Shuffle Downloads", systemImage: "shuffle") {
            player.play(.local(songs), from: .songs(String(localized: "Downloads")), shuffled: true)
        }
        .disabled(songs.isEmpty)
    }
}
