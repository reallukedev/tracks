import SwiftUI
import TracksCore

/// Everything downloaded to this Mac, to look after: a strip at the top with the room it takes
/// and what you play of it, what's coming down or couldn't, then every download in a table
/// that sorts, plays on a double-click, and removes with Delete.
struct LibraryDownloadsPage: View {
    @Environment(YourMusic.self) private var music
    @Environment(PlayFeed.self) private var feed
    @Environment(PlayerModel.self) private var player
    @AppStorage(AutomaticDownloads.storageKey) private var automaticDownloads = true
    @State private var sortOrder = [KeyPathComparator(\LibraryDownloadRow.downloadedAt, order: .reverse)]
    @State private var selection: Set<LibraryDownloadRow.ID> = []
    @State private var removing: Set<LibraryDownloadRow.ID> = []
    @State private var confirmsRemoveAll = false
    @State private var confirmsFreeingUp = false
    /// The room left on this Mac, read when the page opens and after anything's removed.
    @State private var freeBytes: Int64?

    var body: some View {
        let downloads = music.downloads
        let songs = downloads.items.values.map { DownloadedSong(track: $0.keptTrack, bytes: $0.bytes, downloadedAt: $0.downloadedAt) }
        let stats = DownloadReport.stats(songs, facts: feed.facts)
        let unplayed = DownloadReport.unplayed(songs, facts: feed.facts)
        let rows = songs.map { song in
            LibraryDownloadRow(
                song: song,
                plays: feed.facts[song.track.identity]?.plays ?? 0,
                artworkURL: music.artworkURL(song.track.artwork)?.absoluteString
            )
        }
        .sorted(using: sortOrder)
        let byID = Dictionary(songs.map { ($0.track.id, $0) }, uniquingKeysWith: { first, _ in first })
        VStack(spacing: 0) {
            LibraryPageHeader(
                title: String(localized: "Downloads"),
                subtitle: songs.isEmpty ? nil : String(localized: "\(String(AttributedString(localized: "^[\(stats.songs) song](inflect: true)").characters)) · \(LocalFormat.bytes(stats.bytes))"),
                shuffle: songs.isEmpty ? nil : { player.play(.local(rows.compactMap { byID[$0.id]?.track }), from: context, shuffled: true) }
            )
            if songs.isEmpty, downloads.progress.isEmpty, downloads.failures.isEmpty {
                emptyState
            } else {
                summary(stats: stats, unplayed: unplayed)
                    .padding(.horizontal, PlayMetrics.margin)
                    .padding(.bottom, 16)
                activity
                table(rows: rows, byID: byID)
            }
        }
        .navigationTitle("Downloads")
        .toolbar(removing: .title)
        .toolbar {
            ToolbarSpacer(.flexible)
            ToolbarItem(placement: .libraryAction) {
                Menu("More", systemImage: "ellipsis") {
                    Toggle("Automatic Downloads", isOn: $automaticDownloads)
                    Divider()
                    Button("Free Up Space…", systemImage: "leaf") { confirmsFreeingUp = true }
                        .disabled(unplayed.isEmpty)
                    Button("Remove All Downloads…", systemImage: "trash", role: .destructive) { confirmsRemoveAll = true }
                        .disabled(songs.isEmpty)
                }
                .help("More")
            }
        }
        .task(id: downloads.items.count) { freeBytes = await Self.freeSpace() }
        .confirmationDialog(removeTitle(byID), isPresented: Binding(get: { !removing.isEmpty }, set: { if !$0 { removing = [] } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                downloads.remove(removing)
                selection.subtract(removing)
                removing = []
            }
        } message: {
            Text("They stay on your servers, to download again whenever you like.")
        }
        .confirmationDialog("Remove All Downloads?", isPresented: $confirmsRemoveAll, titleVisibility: .visible) {
            Button("Remove All", role: .destructive) { downloads.removeAll() }
        } message: {
            Text("\(String(AttributedString(localized: "^[\(stats.songs) song](inflect: true)").characters)) and \(LocalFormat.bytes(stats.bytes)). They stay on your servers, to download again whenever you like.")
        }
        .confirmationDialog("Free Up \(LocalFormat.bytes(unplayed.map(\.bytes).reduce(0, +)))?", isPresented: $confirmsFreeingUp, titleVisibility: .visible) {
            Button("Remove ^[\(unplayed.count) Song](inflect: true)", role: .destructive) {
                downloads.remove(Set(unplayed.map(\.id)))
            }
        } message: {
            Text("Removes the songs you haven't played in three months. They stay on your servers, to download again whenever you like.")
        }
    }

    private var context: PlayContext { .songs(String(localized: "Downloads")) }

    // MARK: Parts

    /// The strip at the top: storage on the left, what's downloaded on the right.
    private func summary(stats: DownloadReport.Stats, unplayed: [DownloadedSong]) -> some View {
        HStack(alignment: .top, spacing: 32) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Storage")
                    .font(.headline)
                StorageBar(downloads: stats.bytes, files: music.fileBytes, free: freeBytes)
                if !unplayed.isEmpty {
                    Button("Free Up \(LocalFormat.bytes(unplayed.map(\.bytes).reduce(0, +)))…") { confirmsFreeingUp = true }
                        .buttonStyle(.link)
                        .help("Remove the songs you haven't played in three months")
                }
            }
            .frame(maxWidth: 360, alignment: .leading)
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
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
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color.cardFill, in: .rect(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// What's coming down, and what couldn't, above the table while there's any.
    @ViewBuilder
    private var activity: some View {
        let downloads = music.downloads
        let active = downloads.progress.keys.sorted().compactMap { id in music.index.track(id: id).map { ($0, downloads.progress[id] ?? 0) } }
        let failed = downloads.failures.keys.sorted().compactMap { id in music.index.track(id: id).map { ($0, downloads.failures[id] ?? "") } }
        if !active.isEmpty || !failed.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !active.isEmpty {
                    let progress = active.map(\.1).reduce(0, +) / Double(active.count)
                    HStack(spacing: 10) {
                        Text("Downloading ^[\(active.count) Song](inflect: true)")
                            .font(.callout.weight(.semibold))
                        ProgressView(value: progress)
                            .frame(maxWidth: 220)
                            .controlSize(.small)
                        Button("Stop") { downloads.cancel(Set(active.map(\.0.id))) }
                            .controlSize(.small)
                    }
                }
                if !failed.isEmpty {
                    HStack(spacing: 10) {
                        Label("^[\(failed.count) Song](inflect: true) Couldn't Download", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.red)
                            .help(failed.map { "\($0.0.title): \($0.1)" }.joined(separator: "\n"))
                        Button("Try Again") { downloads.retryFailed() }
                            .controlSize(.small)
                    }
                }
            }
            .padding(.horizontal, PlayMetrics.margin)
            .padding(.bottom, 12)
        }
    }

    private func table(rows: [LibraryDownloadRow], byID: [String: DownloadedSong]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Title", value: \.title) { row in
                HStack(spacing: 8) {
                    CoverImage(cover: row.cover, size: 22)
                    Text(row.title)
                        .lineLimit(1)
                        .foregroundStyle(player.current?.local?.id == row.id ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                }
            }
            .width(min: 140, ideal: 220)
            TableColumn("Artist", value: \.artist) { row in Text(row.artist).lineLimit(1) }
                .width(min: 90, ideal: 130)
            TableColumn("Album", value: \.album) { row in Text(row.album).lineLimit(1) }
                .width(min: 90, ideal: 150)
            TableColumn("Size", value: \.bytes) { row in
                Text(LocalFormat.bytes(row.bytes)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 76, max: 96)
            .alignment(.trailing)
            TableColumn("Your Plays", value: \.plays) { row in
                Text(row.plays > 0 ? row.plays.formatted() : "").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 64, ideal: 76, max: 96)
            .alignment(.numeric)
            TableColumn("Downloaded", value: \.downloadedAt) { row in
                Text(row.downloadedAt.formatted(date: .abbreviated, time: .omitted)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 86, ideal: 104, max: 140)
        }
        .contextMenu(forSelectionType: LibraryDownloadRow.ID.self) { ids in
            let tracks = rows.filter { ids.contains($0.id) }.compactMap { byID[$0.id]?.track }
            if tracks.count == 1, let track = tracks.first {
                LocalTrackMenu(track: track, showsStats: true)
            } else if !tracks.isEmpty {
                let title = String(AttributedString(localized: "^[\(tracks.count) song](inflect: true)").characters)
                Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { player.enqueue(.local(tracks), next: true, title: title) }
                Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") { player.enqueue(.local(tracks), next: false, title: title) }
                Divider()
                Button("Remove ^[\(tracks.count) Download](inflect: true)…", systemImage: "trash", role: .destructive) { removing = ids }
            }
        } primaryAction: { ids in
            let queue = rows.compactMap { byID[$0.id]?.track }
            guard let start = queue.firstIndex(where: { ids.contains($0.id) }) else { return }
            player.play(.local(queue, startingAt: start), from: context)
        }
        .onDeleteCommand {
            if !selection.isEmpty { removing = selection }
        }
    }

    private var emptyState: some View {
        PlayStateCard(
            symbol: "arrow.down.circle",
            title: String(localized: "Nothing Downloaded"),
            message: String(localized: "Songs you play from your servers download here with Automatic Downloads, to play anywhere, even with no connection.")
        ) {
            if !automaticDownloads {
                Button("Turn On Automatic Downloads") { automaticDownloads = true }
                    .buttonStyle(.borderedProminent)
            }
        }
        .libraryStateWidth()
        .padding(.horizontal, PlayMetrics.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func removeTitle(_ byID: [String: DownloadedSong]) -> String {
        let bytes = removing.compactMap { byID[$0]?.bytes }.reduce(0, +)
        if removing.count == 1, let title = removing.first.flatMap({ byID[$0]?.track.title }) {
            return String(localized: "Remove the Download of \u{201C}\(title)\u{201D}?")
        }
        return String(localized: "Remove ^[\(removing.count) Download](inflect: true), \(LocalFormat.bytes(bytes))?")
    }

    /// The room left on this Mac for things people keep.
    @concurrent
    private static func freeSpace() async -> Int64? {
        let values = try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

/// A download in the table.
nonisolated struct LibraryDownloadRow: Identifiable, Sendable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let bytes: Int64
    let plays: Int
    let downloadedAt: Date
    let cover: CoverArt

    init(song: DownloadedSong, plays: Int, artworkURL: String?) {
        id = song.track.id
        title = song.track.title
        artist = song.track.artist
        album = song.track.album ?? ""
        bytes = song.bytes
        self.plays = plays
        downloadedAt = song.downloadedAt
        cover = .url(artworkURL, seed: song.track.album ?? song.track.title)
    }
}
