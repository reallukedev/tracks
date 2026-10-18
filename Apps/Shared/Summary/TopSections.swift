import SwiftUI
import TracksCore

/// A horizontal shelf of artists, like the Music app's.
struct TopArtistsShelf: View {
    let artists: [ArtistTally]
    var artworkSize: CGFloat = 96
    /// Songs under each name rather than plays, for collaborators, whose tallies count only
    /// what they share.
    var countsSongs = false

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 16) {
                ForEach(artists) { artist in
                    NavigationLink(value: Route.artist(artist.id)) {
                        VStack(spacing: 8) {
                            ArtworkView(url: artist.artworkURL, seed: artist.name, size: artworkSize, isCircle: true)
                            VStack(spacing: 1) {
                                Text(artist.name)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Group {
                                    if countsSongs {
                                        Text("^[\(artist.songCount) song](inflect: true)")
                                    } else {
                                        Text("^[\(artist.count) play](inflect: true)")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText(value: Double(countsSongs ? artist.songCount : artist.count)))
                            }
                        }
                        .frame(width: artworkSize + 8)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(countsSongs ? Text("\(artist.name), ^[\(artist.songCount) song](inflect: true) together") : Text("\(artist.name), \(artist.count) plays"))
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 4)
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
        .shelfBleed()
    }
}

/// Numbered song rows inside a card.
struct TopSongsCard: View {
    let songs: [SongTally]
    var limit = 5

    var body: some View {
        let shown = Array(songs.prefix(limit))
        Card(padding: 0) {
            VStack(spacing: 0) {
                ForEach(shown.enumerated(), id: \.element.id) { index, song in
                    NavigationLink(value: Route.song(song.id)) {
                        SongRow(song: song, rank: index + 1, widestRank: shown.count)
                            .padding(.horizontal, Metrics.cardPadding)
                            .padding(.vertical, 8)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    // Where a collaboration's other artists are a press away on iPhone.
                    .contextMenu { ChartSongMenu(song: MixSong(tally: song)) }
                    if index < shown.count - 1 {
                        SongRowSeparator(widestRank: shown.count)
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }
}

/// A row's rank, as wide as the widest rank in its list: the covers after it line up, and a
/// "1" doesn't leave a gutter wider than the card's padding.
struct RankLabel: View {
    let rank: Int
    let widestRank: Int

    var body: some View {
        ZStack(alignment: .trailing) {
            Text(widestRank.formatted())
                .hidden()
            Text(rank.formatted())
                .contentTransition(.numericText(value: Double(rank)))
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
}

/// The line between two ``SongRow``s, starting where the title does. It repeats the row's
/// leading columns, invisibly, so it follows the rank's width and the text size.
struct SongRowSeparator: View {
    let widestRank: Int

    var body: some View {
        HStack(spacing: SongRow.spacing) {
            // Only its width counts; a line of text's height would space the rows apart.
            RankLabel(rank: widestRank, widestRank: widestRank)
                .hidden()
                .frame(height: 0)
            Color.clear
                .frame(width: SongRow.artworkSize, height: 0)
            // Wrapped so it's drawn across, not down.
            VStack { Divider() }
        }
        .padding(.leading, Metrics.cardPadding)
        .accessibilityHidden(true)
    }
}

/// Rank, cover, title and artist, and the play count.
struct SongRow: View {
    static let spacing: CGFloat = 12
    static let artworkSize: CGFloat = 44

    let song: SongTally
    var rank: Int?
    /// The largest rank in the list, which sets the width of the rank column.
    var widestRank: Int?
    var showsCount = true
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                ArtworkView(url: song.artworkURL, seed: song.albumTitle ?? song.title, size: 44)
                Text(rank.map { "\($0). \(song.title)" } ?? song.title)
                CreditedText(text: song.artistName, credits: song.credits, linkStyle: .row)
                    .foregroundStyle(.secondary)
                if showsCount {
                    Text("^[\(song.count) play](inflect: true)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: Self.spacing) {
            if let rank {
                RankLabel(rank: rank, widestRank: widestRank ?? rank)
            }
            ArtworkView(url: song.artworkURL, seed: song.albumTitle ?? song.title, size: Self.artworkSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .lineLimit(1)
                CreditedText(text: song.artistName, credits: song.credits, linkStyle: .row)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if showsCount {
                Text("^[\(song.count) play](inflect: true)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(song.count)))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Album covers in a horizontal shelf.
struct TopAlbumsShelf: View {
    let albums: [AlbumTally]
    var coverSize: CGFloat = 140

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(albums) { album in
                    NavigationLink(value: Route.album(album.id)) {
                        VStack(alignment: .leading, spacing: 6) {
                            ArtworkView(url: album.artworkURL, seed: album.title, size: coverSize)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(album.title)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Text(album.artistName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(width: coverSize)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 4)
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
        .shelfBleed()
    }
}

extension View {
    /// On iPhone a shelf runs out to the screen's edges, as Music's do, rather than stopping
    /// at the page's margin. The Mac keeps it inside the column, clear of the sidebar.
    func shelfBleed() -> some View {
        #if os(iOS)
        scrollClipDisabled()
        #else
        self
        #endif
    }
}
