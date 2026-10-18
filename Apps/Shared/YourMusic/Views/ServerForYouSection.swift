import SwiftUI
import TracksCore

/// One of the shelves a server fills for you, in columns of four as Music lays out songs:
/// Picked for You, songs by the artists you play and ones like them, yours and new together;
/// or Suggested Songs, songs by artists new to you, led by Tracks Radio. Both go on for as long
/// as they're scrolled: the last column coming into view asks for more, as fast as the
/// server's budget allows. With Octo in front of the server most are songs it finds: they play straight away,
/// and Add to Your Music has Octo fetch the file. Needs no Apple Music, no listening history and
/// no library, only artists to start from, which Picked for You asks for when there are none.
struct ServerForYouSection: View {
    let server: SubsonicServer
    var shelf: ServerDiscovery.Shelf = .picks
    /// Off where Tracks Radio leads the crate above instead.
    var includesRadio = true

    @Environment(YourMusic.self) private var music
    @Environment(PlayFeed.self) private var feed
    @Environment(PlayerModel.self) private var player
    @AppStorage(PlayPreferences.tracksRadioKey) private var isRadioOn = true
    @State private var picksArtists = false
    /// The columns on screen: while the last is among them, more are found.
    @State private var columnsInView: [LocalTrack.ID] = []
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 64

    var body: some View {
        let forYou = music.discover.forYou[server.id]
        let songs = songs(of: forYou)
        let hasStart = !(forYou?.from.isEmpty ?? true)
        let goesOn = forYou.map { $0.isFilling || $0.canGoOn } ?? true
        let columns = SuggestionShelfPaging.columns(of: songs, goesOn: goesOn)
        // With nothing to show yet, the loading columns are the end, and in view.
        let isEndInView = columns.isEmpty || columns.last.map { columnsInView.contains($0.id) } ?? false
        // Suggested Songs needs artists to start from; Picked for You asks for them.
        if shelf == .picks || hasStart || forYou == nil {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    ShelfHeader(title: title) {
                        if shelf == .picks { menu(songs: songs) }
                    }
                    if let subtitle = subtitle(forYou) {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.horizontal, PlayMetrics.margin)

                if let forYou {
                    if !hasStart {
                        startCard
                            .padding(.horizontal, PlayMetrics.margin)
                    } else if songs.isEmpty, !forYou.isFilling, !forYou.canGoOn {
                        Text(emptyNote)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, PlayMetrics.margin)
                    } else {
                        shelf(songs, columns: columns, goesOn: goesOn)
                    }
                } else {
                    shelf([], columns: [], goesOn: true)
                }
            }
            .animation(.snappy, value: songs.count)
            .sheet(isPresented: $picksArtists) { SeedArtistPicker() }
            .task(id: LoadKey(serverID: server.id, picked: music.discover.pickedArtists, played: feed.tasteArtists)) {
                await load(force: false)
            }
            // A column at a time while the last is in view, as the budget allows: asked again
            // after each answer, even one that found nothing.
            .task(id: "\(isEndInView).\(songs.count).\(forYou?.canGoOn == true).\(music.discover.answers[server.id] ?? 0)") {
                guard isEndInView else { return }
                await music.discover.loadMore(
                    for: server.id,
                    shelf: shelf,
                    want: SuggestionPaging.wanted(showing: songs.count, perColumn: SuggestionShelfPaging.rowsPerColumn)
                )
            }
        }
    }

    private struct LoadKey: Equatable {
        let serverID: String
        let picked: [String]
        let played: [String]
    }

    private func songs(of forYou: ServerDiscovery.ForYou?) -> [LocalTrack] {
        switch shelf {
        case .picks: forYou?.songs ?? []
        case .suggested: forYou?.suggested ?? []
        case .further: forYou?.further ?? []
        }
    }

    private var title: String {
        shelf == .suggested ? String(localized: "Suggested Songs") : String(localized: "Picked for You")
    }

    private func subtitle(_ forYou: ServerDiscovery.ForYou?) -> String? {
        guard let from = forYou?.from, !from.isEmpty else { return nil }
        switch shelf {
        case .picks: return String(localized: "From \(from.formatted(.list(type: .and))), and artists like them")
        case .suggested, .further: return String(localized: "Artists new to you, like the ones you play")
        }
    }

    private var emptyNote: String {
        String(localized: "\(server.name) didn't find anything to suggest. If it's Octo, it needs a Last.fm API key, set on its admin page.")
    }

    private func load(force: Bool) async {
        await music.discover.loadForYou(
            for: server.id,
            heard: { [feed, player] in feed.facts[$0] != nil || player.signals.excludes($0) },
            knowsArtist: { [feed] in feed.heardArtists.contains(StatsCalculator.folded($0)) },
            played: feed.tasteArtists,
            force: force
        )
    }

    private func menu(songs: [LocalTrack]) -> some View {
        Menu("More", systemImage: "ellipsis.circle") {
            Button("Choose Artists", systemImage: "music.microphone") { picksArtists = true }
            Button("Pick Again", systemImage: "arrow.clockwise") {
                Task { await load(force: true) }
            }
            let toAdd = songs.filter { $0.isFromServer && !music.isInYourMusic($0) && !music.servers.isWaitingToKeep($0) }
            if !toAdd.isEmpty {
                Divider()
                Button("Add All to Your Music", systemImage: "plus.circle") {
                    Task {
                        for track in toAdd { _ = await music.keep(track) }
                        player.confirm(String(AttributedString(localized: "Adding ^[\(toAdd.count) song](inflect: true) to Your Music").characters))
                    }
                }
            }
        }
        .labelStyle(.iconOnly)
        .iconMenuStyle()
    }

    private var startCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Pick a few artists you like, and \(server.name) finds songs by them and artists like them, to play straight away and add to your music.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Pick Artists") { picksArtists = true }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardFill, in: .rect(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    /// The songs in columns, Tracks Radio first on Suggested Songs.
    /// - Parameters:
    ///   - columns: whole columns only while more are coming, so the end is never a column of
    ///     gaps; more are asked for as the last comes into view.
    ///   - goesOn: more are coming: with nothing to show yet, loading columns give the shelf
    ///     its shape.
    private func shelf(_ songs: [LocalTrack], columns: [SuggestionColumn<LocalTrack>], goesOn: Bool) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: PlayMetrics.shelfSpacing) {
                if shelf == .suggested, isRadioOn, includesRadio {
                    TracksRadioTile(side: rowHeight * CGFloat(SuggestionShelfPaging.rowsPerColumn))
                }
                ForEach(columns) { column in
                    VStack(spacing: 0) {
                        ForEach(column.items) { track in
                            row(track, in: songs)
                            if track.id != column.items.last?.id {
                                Divider().padding(.leading, 60)
                            }
                        }
                    }
                    .containerRelativeFrame(.horizontal, alignment: .leading) { length, _ in
                        SuggestionShelfPaging.columnWidth(in: length)
                    }
                }
                if columns.isEmpty, goesOn {
                    ForEach(0..<2, id: \.self) { column in
                        loadingColumn(offset: column)
                    }
                }
            }
            .scrollTargetLayout()
            .animation(PlayMotion.row, value: columns.map(\.id))
        }
        .contentMargins(.horizontal, PlayMetrics.margin, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
        // Half in view counts, so a column peeking in at the edge doesn't.
        .onScrollTargetVisibilityChange(idType: LocalTrack.ID.self, threshold: 0.5) { columnsInView = $0 }
    }

    private func loadingColumn(offset: Int) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<SuggestionShelfPaging.rowsPerColumn, id: \.self) { row in
                LoadingRow(width: [0.62, 0.48, 0.7, 0.4][(row + offset) % 4])
                    .frame(height: rowHeight)
            }
        }
        .containerRelativeFrame(.horizontal, alignment: .leading) { length, _ in
            SuggestionShelfPaging.columnWidth(in: length)
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Loading"))
        .transition(.opacity)
    }

    private func row(_ track: LocalTrack, in songs: [LocalTrack]) -> some View {
        HStack(spacing: 4) {
            Button {
                player.play(.local(songs, startingAt: songs.firstIndex(of: track) ?? 0), from: .songs(title))
            } label: {
                LocalTrackRow(track: track, isCurrent: player.current?.local?.id == track.id)
            }
            .buttonStyle(.plain)
            AddFoundSongButton(track: track)
        }
        .frame(height: rowHeight)
        .contextMenu { LocalTrackMenu(track: track) }
    }
}
