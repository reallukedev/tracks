import SwiftUI
import MusicKit
import TracksCore

/// The song at the top of its info: cover, name, artist and album, how it's mastered, and
/// Play beside the song's own menu.
struct SongInfoHeader: View {
    let subject: SongInfoSubject
    let info: SongInfoModel
    @Environment(PlayerModel.self) private var player
    @Environment(YourMusic.self) private var music
    @Environment(\.openPlayRoute) private var openPlayRoute
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The round buttons' symbol area, so they stay as tall as Play beside them at any size.
    #if os(macOS)
    @ScaledMetric(relativeTo: .body) private var moreSide: CGFloat = 16
    #else
    @ScaledMetric(relativeTo: .body) private var moreSide: CGFloat = 20
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
            layout {
                cover
                titles
            }
            buttons
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var cover: some View {
        if let local = subject.local {
            LocalCover(artwork: local.artwork, seed: local.album ?? local.title, size: Self.coverSize)
                .frame(width: Self.coverSize, height: Self.coverSize)
        } else {
            CoverImage(cover: coverArt, size: Self.coverSize)
        }
    }

    /// The song as the history knows it, for what the place Get Info came from didn't say.
    private var played: SongTally? { info.history.value?.profile?.song }

    /// A song known only by name (a sample, a similar song) borrows its cover from your
    /// history or Apple Music once either has it.
    private var coverArt: CoverArt {
        if case .url(nil, let seed) = subject.cover {
            if let url = played?.artworkURL { return .url(url, seed: seed) }
            if let artwork = info.catalogSong?.artwork, !player.isDemo { return .artwork(artwork) }
        }
        return subject.cover
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(subject.title)
                .font(.title2.bold())
                .lineLimit(3)
                .accessibilityAddTraits(.isHeader)
            if let goToArtist = actions.goToArtist {
                Button(action: goToArtist) {
                    Text(subject.artistName)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .font(.title3)
                .lineLimit(2)
                .accessibilityHint("Shows the artist")
                #if os(macOS)
                .pointerStyle(.link)
                #endif
            } else {
                Text(subject.artistName)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let album = albumLine {
                Text(album)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            badges
                .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Coastlines · 2024".
    private var albumLine: String? {
        let about = info.about.value
        let year = about?.releaseYear ?? about?.year ?? info.history.value?.profile?.metadata?.releaseYear ?? info.credits.value?.firstReleaseYear
        let album = subject.albumTitle ?? played?.albumTitle ?? (player.isDemo ? nil : info.catalogSong?.albumTitle)
        let parts = [album, year.map(Format.year)].compactMap(\.self)
        // Unbreaking spaces, so a wrapped line never starts with the dot.
        return parts.isEmpty ? nil : parts.joined(separator: "\u{00A0}·\u{00A0}")
    }

    @ViewBuilder
    private var badges: some View {
        if let about = info.about.value, about.isExplicit || about.format != nil || !about.qualities.isEmpty {
            TagFlow(spacing: 6) {
                if about.isExplicit {
                    AboutQualityBadge(label: String(localized: "Explicit"), symbol: "e.square.fill")
                }
                if let format = about.format {
                    FormatBadge(format: format, showsDetail: true)
                }
                ForEach(about.qualities, id: \.label) { quality in
                    AboutQualityBadge(quality: quality)
                }
            }
        }
    }

    /// Play, then the song's most used actions as round buttons, then everything else in More.
    /// At the largest text sizes the round buttons fold into More.
    private var buttons: some View {
        let actions = actions
        let showsRound = !typeSize.isAccessibilitySize
        return HStack(spacing: 10) {
            if let play {
                Button("Play", systemImage: "play.fill", action: play)
                    .buttonStyle(.glassProminent)
            }
            if showsRound {
                if let station = actions.createStation {
                    RoundButton(title: "Create Station", systemImage: "dot.radiowaves.left.and.right", side: moreSide, action: station)
                }
                if let add = actions.addToLibrary {
                    RoundButton(title: "Add to Library", systemImage: "plus", side: moreSide, action: add)
                }
                if let share = actions.share {
                    ShareButton(share: share, side: moreSide)
                }
            }
            Menu {
                SongMenuItems(showsRound ? actions.withoutRoundButtons : actions)
            } label: {
                // As tall as Play beside it.
                Image(systemName: "ellipsis")
                    .frame(width: moreSide, height: moreSide)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("More")
            #if os(macOS)
            .help("More")
            #endif
        }
        .buttonBorderShape(.capsule)
        .controlSize(.large)
    }

    // MARK: - Actions

    /// The song's own menu, less what the page already offers (Play, and Get Info itself) and
    /// Add to Playlist, whose picker belongs to the main window.
    private var actions: SongActions {
        let go = openPlayRoute.ifPushes
        var actions: SongActions
        if let local = subject.local {
            actions = .local(local, music: music, player: player, go: go ?? { _ in })
            if go == nil { actions.stats = nil }
        } else if let song = info.catalogSong, !player.isDemo {
            actions = .catalog(song, player: player, go: go)
        } else {
            actions = .history(historySong, player: player, go: go)
        }
        actions.play = nil
        actions.info = nil
        actions.playlistTracks = []
        return actions
    }

    private var play: (() -> Void)? {
        let title = subject.title
        if let local = subject.local {
            return music.isPlayable(local) ? { player.play(.local([local]), from: .songs(title)) } : nil
        }
        if let song = info.catalogSong, !player.isDemo {
            return { player.play(.songs([song]), from: .songs(title)) }
        }
        let song = historySong
        guard player.canPlay(songID: song.songID) else { return nil }
        return { player.play(.history([HistorySong(song)]), from: .songs(title)) }
    }

    private var historySong: MixSong {
        MixSong(
            songIdentity: subject.identity,
            songID: subject.catalogID ?? "",
            title: subject.title,
            artistName: subject.artistName,
            albumTitle: subject.albumTitle,
            artworkURL: nil,
            plays: 0,
            lastHeard: .distantPast
        )
    }

    #if os(macOS)
    private static let coverSize: CGFloat = 112
    #else
    private static let coverSize: CGFloat = 96
    #endif
}

/// A round glass button with only its symbol, named for VoiceOver and the pointer.
private struct RoundButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let side: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: side, height: side)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(Text(title))
        #if os(macOS)
        .help(Text(title))
        #endif
    }
}

private struct ShareButton: View {
    let share: SongShare
    let side: CGFloat

    var body: some View {
        Group {
            switch share {
            case .url(let url): ShareLink(item: url) { icon }
            case .text(let text): ShareLink(item: text) { icon }
            }
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel("Share")
        #if os(macOS)
        .help("Share")
        #endif
    }

    private var icon: some View {
        Image(systemName: "square.and.arrow.up")
            .frame(width: side, height: side)
    }
}

private extension SongActions {
    /// More's items when the round buttons beside it already offer some.
    var withoutRoundButtons: SongActions {
        var actions = self
        actions.createStation = nil
        actions.addToLibrary = nil
        actions.share = nil
        return actions
    }
}
