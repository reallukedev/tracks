import SwiftUI
import TracksCore

/// A titled list of an artist's songs. Five rows on iPhone, a line between each as in Music;
/// on the Mac two columns of compact rows, Music's Top Songs there. "See All" opens the rest.
struct ArtistSongsSection<Content: View, Destination: View>: View {
    let title: String
    var showsSeeAll = false
    @ViewBuilder var destination: Destination
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtistSectionTitle(title: title) {
                if showsSeeAll {
                    NavigationLink("See All") { destination }
                        .buttonStyle(.borderless)
                }
            }
            Group(subviews: content) { rows in
                #if os(macOS)
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 24, alignment: .top), GridItem(.flexible(), alignment: .top)],
                    alignment: .leading,
                    spacing: 2
                ) {
                    ForEach(rows) { $0 }
                }
                .padding(.horizontal, PlayMetrics.margin - ArtistSongLabel.hoverInset)
                #else
                VStack(spacing: 0) {
                    ForEach(rows.indices, id: \.self) { index in
                        rows[index]
                        if index < rows.count - 1 {
                            Divider().padding(.leading, 60)
                        }
                    }
                }
                .padding(.horizontal, PlayMetrics.margin)
                #endif
            }
        }
    }

    /// How many rows the section shows before See All.
    static var visibleRows: Int {
        #if os(macOS)
        10
        #else
        5
        #endif
    }
}

extension ArtistSongsSection where Destination == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.showsSeeAll = false
        self.destination = EmptyView()
        self.content = content()
    }
}

/// A section's title at the page's leading edge, with something trailing it.
struct ArtistSectionTitle<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        AdaptiveStack(verticalAlignment: .firstTextBaseline, spacing: 4) {
            Text(title)
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing
                #if os(iOS)
                .font(.subheadline)
                #endif
        }
        .padding(.horizontal, PlayMetrics.margin)
    }
}

/// One of an artist's songs, drawn for the platform: Music's track row on iPhone, a compact
/// row on the Mac that brightens under the pointer and shows Play over its cover. The page
/// wraps it in whatever plays it.
struct ArtistSongLabel: View {
    let title: String
    let subtitle: String?
    let cover: CoverArt
    var plays: Int?
    var isExplicit = false
    var isCurrent = false
    /// A song of yours, for its download coming down.
    var localTrack: LocalTrack?
    var isPlayable = true

    #if os(macOS)
    /// How far the hover highlight reaches past the row's content.
    static let hoverInset: CGFloat = 8
    @Environment(PlayerModel.self) private var player
    @State private var isHovered = false
    #else
    static let hoverInset: CGFloat = 0
    #endif

    var body: some View {
        #if os(macOS)
        HStack(spacing: 12) {
            CoverImage(cover: cover, size: 40)
                .overlay {
                    if isCurrent || isHovered {
                        RoundedRectangle(cornerRadius: CoverImage.radius(for: 40), style: .continuous)
                            .fill(.black.opacity(0.4))
                        Group {
                            if isCurrent {
                                PlayingWaveform(isActive: player.isPlaying, color: .white)
                            } else {
                                Image(systemName: "play.fill")
                            }
                        }
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title)
                        .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                    if isExplicit { ExplicitBadge() }
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let localTrack {
                DownloadStateIcon(track: localTrack)
            }
            if let plays, plays > 0 {
                Text(PlayCountText.short(plays))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(PlayCountText.spoken(plays))
            }
        }
        .padding(.horizontal, Self.hoverInset)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(isHovered ? 1 : 0), in: .rect(cornerRadius: 8, style: .continuous))
        .opacity(isPlayable ? 1 : 0.45)
        .contentShape(.rect)
        .onHover { hovering in withAnimation(PlayMotion.hover) { isHovered = hovering } }
        .accessibilityElement(children: .combine)
        #else
        TrackRow(title: title, subtitle: subtitle, cover: cover, plays: plays, isExplicit: isExplicit, isCurrent: isCurrent, localTrack: localTrack, isPlayable: isPlayable)
            .padding(.vertical, 6)
        #endif
    }
}

/// Your own most played songs by an artist, from the history.
struct ArtistYourTopSongs: View {
    let artist: String
    let songs: [MixSong]
    @Environment(PlayerModel.self) private var player

    var body: some View {
        let visible = songs.prefix(ArtistSongsSection<EmptyView, EmptyView>.visibleRows)
        ArtistSongsSection(title: String(localized: "Your Top Songs"), showsSeeAll: songs.count > visible.count) {
            ArtistSongListPage(title: String(localized: "Your Top Songs"), artist: artist) { rows }
        } content: {
            ForEach(visible) { song in row(song) }
        }
    }

    private var rows: some View {
        ForEach(songs) { song in row(song) }
    }

    private func row(_ song: MixSong) -> some View {
        Button {
            play(from: song)
        } label: {
            ArtistSongLabel(
                title: song.title,
                subtitle: song.albumTitle,
                cover: .url(song.artworkURL, seed: song.albumTitle ?? song.title),
                plays: song.plays,
                isCurrent: player.current?.songIdentity == song.songIdentity,
                isPlayable: player.canPlay(songID: song.songID)
            )
        }
        .buttonStyle(.plain)
        .contextMenu { HistorySongMenu(song: song) }
    }

    private func play(from song: MixSong) {
        let playable = songs.filter { player.canPlay(songID: $0.songID) }
        guard let start = playable.firstIndex(of: song) else { return }
        player.play(.history(playable.map(HistorySong.init), startingAt: start), from: PlayContext(kind: .artist, title: artist))
    }
}

/// All of an artist's songs in one list, from See All.
struct ArtistSongListPage<Rows: View>: View {
    let title: String
    let artist: String
    @ViewBuilder var rows: Rows

    var body: some View {
        List {
            rows
                #if os(macOS)
                .listRowSeparator(.hidden)
                #endif
        }
        .listStyle(.plain)
        .navigationTitle(title)
        #if os(macOS)
        .navigationSubtitle(artist)
        #else
        .toolbarTitleDisplayMode(.inline)
        #endif
    }
}

/// An artist's newest album or single as a wide card: its cover, when it came out, its name.
struct ArtistLatestRelease<Menu: View>: View {
    let title: String
    let cover: CoverArt
    var released: Date?
    var detail: String?
    let route: PlayRoute
    @ViewBuilder var menu: Menu

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ArtistSectionTitle(title: String(localized: "Latest Release")) { EmptyView() }
            NavigationLink(value: route) {
                HStack(spacing: 16) {
                    CoverImage(cover: cover, size: Self.coverSide)
                    VStack(alignment: .leading, spacing: 3) {
                        if let released {
                            Text(released.formatted(.dateTime.month(.abbreviated).day().year()))
                                .textCase(.uppercase)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        if let detail {
                            Text(detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .frame(maxWidth: Self.maximumWidth, alignment: .leading)
                .background(Color.cardFill, in: .rect(cornerRadius: Metrics.cardRadius, style: .continuous))
                .contentShape(.rect(cornerRadius: Metrics.cardRadius, style: .continuous))
                .hoverLift()
                .accessibilityElement(children: .combine)
            }
            .buttonStyle(.pressable)
            .contextMenu { menu }
            .padding(.horizontal, PlayMetrics.margin)
        }
    }

    #if os(macOS)
    private static var coverSide: CGFloat { 112 }
    private static var maximumWidth: CGFloat { 480 }
    #else
    private static var coverSide: CGFloat { 96 }
    private static var maximumWidth: CGFloat { .infinity }
    #endif
}

/// An artist as a round picture with their name under it, for Similar Artists.
struct ArtistCircleTile: View {
    let name: String
    let picture: CoverArt?
    var detail: String?
    @ScaledMetric(relativeTo: .subheadline) private var scaledSide: CGFloat = 120

    var body: some View {
        VStack(spacing: 8) {
            ArtistPicture(cover: picture, name: name, size: side)
                .hoverLift()
            VStack(spacing: 1) {
                Text(name)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let detail {
                    Text(detail)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .font(Self.font)
            .multilineTextAlignment(.center)
        }
        .frame(width: side)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var side: CGFloat {
        #if os(macOS)
        150
        #else
        min(scaledSide, 180)
        #endif
    }

    #if os(macOS)
    private static let font = Font.callout
    #else
    private static let font = Font.subheadline
    #endif
}

/// A state the page is in, in place under the header: couldn't load, not found.
struct ArtistPageMessage<Actions: View>: View {
    let title: String
    let symbol: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        PlayStateCard(symbol: symbol, title: title, message: message) { actions }
            .libraryStateWidth()
            .padding(.horizontal, PlayMetrics.margin)
    }
}

/// The songs part of an artist's page while it loads: a title and rows in their shape.
struct ArtistLoadingSections: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtistSectionTitle(title: String(localized: "Top Songs")) { EmptyView() }
                .redacted(reason: .placeholder)
            #if os(macOS)
            HStack(alignment: .top, spacing: 24) {
                LoadingRows(count: 5)
                LoadingRows(count: 5)
            }
            .padding(.horizontal, PlayMetrics.margin)
            #else
            LoadingRows(count: 5)
                .padding(.horizontal, PlayMetrics.margin)
            #endif
        }
    }
}
