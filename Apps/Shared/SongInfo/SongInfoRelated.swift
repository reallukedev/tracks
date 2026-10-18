import SwiftUI
import MusicKit
import TracksCore

// MARK: - The album

/// The song's album in order, with the song itself marked. Without Apple Music or a file of
/// your own, the album's songs you've played instead, as your history knows only those.
struct SongInfoAlbumSection: View {
    let subject: SongInfoSubject
    let related: SongRelated?
    let history: SongInfoHistory?
    @State private var showsAll = false

    /// Rows before Show All, the song itself always among them.
    private static let collapsedCount = 8

    var body: some View {
        if let album = related?.album, !album.isEmpty {
            section("On This Album", rows: album.map(Row.init))
        } else if let played = history?.albumSongs, played.count > 1 {
            section("Played From This Album", rows: played.map(Row.init))
        }
    }

    private func section(_ title: LocalizedStringKey, rows: [Row]) -> some View {
        let currentIndex = rows.firstIndex { $0.subject.identity == subject.identity }
        let shown = showsAll ? Array(rows.indices) : rows.indices.filter { $0 < Self.collapsedCount || $0 == currentIndex }
        let numbered = rows.contains { $0.trackNumber != nil }
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title) {
                if rows.count > shown.count || showsAll {
                    Button(showsAll ? "Show Less" : "Show All") { showsAll.toggle() }
                }
            }
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(shown, id: \.self) { index in
                        if index != shown.first { InsetDivider() }
                        AlbumTrackRow(row: rows[index], isCurrent: index == currentIndex, isNumbered: numbered)
                    }
                }
            }
        }
    }

    fileprivate struct Row {
        let subject: SongInfoSubject
        var trackNumber: Int?
        var duration: TimeInterval?
        var isExplicit = false
        var mix: MixSong?

        init(_ song: RelatedSong) {
            subject = song.subject
            trackNumber = song.trackNumber
            duration = song.duration
            isExplicit = song.isExplicit
        }

        init(_ tally: SongTally) {
            let mix = MixSong(tally: tally)
            subject = SongInfoSubject(mix)
            self.mix = mix
        }
    }
}

private struct AlbumTrackRow: View {
    let row: SongInfoAlbumSection.Row
    let isCurrent: Bool
    let isNumbered: Bool

    var body: some View {
        if isCurrent {
            label
                .accessibilityElement(children: .combine)
                .accessibilityValue(Text("This song"))
        } else {
            NavigationLink(value: row.subject) { label }
                .buttonStyle(.plain)
                .songInfoRowMenu(row.subject, mix: row.mix)
                .accessibilityHint("Shows this song's info")
        }
    }

    private var label: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if isNumbered {
                Text(row.trackNumber.map { $0.formatted() } ?? "")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 20, alignment: .trailing)
                    .accessibilityHidden(row.trackNumber == nil)
            }
            HStack(spacing: 4) {
                Text(row.subject.title)
                    .fontWeight(isCurrent ? .semibold : nil)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .lineLimit(2)
                if row.isExplicit {
                    Image(systemName: "e.square.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Explicit")
                }
            }
            Spacer(minLength: 8)
            if let duration = row.duration, duration > 0 {
                Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if !isCurrent {
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, Metrics.cardPadding)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }
}

// MARK: - The artist

/// The artist's best known songs in Apple Music, or the ones you play most.
struct SongInfoArtistSection: View {
    let subject: SongInfoSubject
    let related: SongRelated?
    let history: SongInfoHistory?

    var body: some View {
        if let top = related?.topSongs, !top.isEmpty {
            section("Top Songs by \(subject.artistName)", rows: top.map { ($0.subject, nil) })
        } else if let yours = history?.artistSongs, !yours.isEmpty {
            section(
                "Your Top Songs by \(subject.artistName)",
                rows: yours.prefix(SongRelated.topSongCount).map { tally in
                    let mix = MixSong(tally: tally)
                    return (SongInfoSubject(mix), mix)
                }
            )
        }
    }

    private func section(_ title: LocalizedStringKey, rows: [(subject: SongInfoSubject, mix: MixSong?)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title)
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(rows.indices, id: \.self) { index in
                        if index > 0 { InsetDivider(inset: Metrics.cardPadding + Self.coverSize + 12) }
                        TopSongRow(subject: rows[index].subject, mix: rows[index].mix)
                    }
                }
            }
        }
    }

    fileprivate static let coverSize: CGFloat = 40
}

private struct TopSongRow: View {
    let subject: SongInfoSubject
    let mix: MixSong?

    var body: some View {
        NavigationLink(value: subject) {
            HStack(spacing: 12) {
                CoverImage(cover: subject.cover, size: SongInfoArtistSection.coverSize)
                VStack(alignment: .leading, spacing: 2) {
                    Text(subject.title)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let album = subject.albumTitle {
                        Text(album)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Metrics.cardPadding)
            .padding(.vertical, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .songInfoRowMenu(subject, mix: mix)
        .accessibilityHint("Shows this song's info")
    }
}

// MARK: - A row's menu

private extension View {
    /// The song's own menu on a row, less Get Info, which the row itself is.
    func songInfoRowMenu(_ subject: SongInfoSubject, mix: MixSong?) -> some View {
        modifier(SongInfoRowMenu(subject: subject, mix: mix))
    }
}

private struct SongInfoRowMenu: ViewModifier {
    let subject: SongInfoSubject
    let mix: MixSong?
    @Environment(PlayerModel.self) private var player
    @Environment(YourMusic.self) private var music
    @Environment(\.openPlayRoute) private var openPlayRoute

    func body(content: Content) -> some View {
        content.contextMenu {
            SongMenuItems(actions)
        }
    }

    private var actions: SongActions {
        let go = openPlayRoute.ifPushes
        let title = subject.title
        var actions: SongActions
        if let local = subject.local {
            let play = music.isPlayable(local) ? { player.play(.local([local]), from: .songs(title)) } : nil
            actions = .local(local, music: music, player: player, play: play, go: go ?? { _ in })
        } else if let song = subject.song, !player.isDemo {
            actions = .catalog(song, player: player, play: { player.play(.songs([song]), from: .songs(title)) }, go: go)
        } else {
            let song = mix ?? MixSong(
                songIdentity: subject.identity,
                songID: subject.catalogID ?? "",
                title: subject.title,
                artistName: subject.artistName,
                albumTitle: subject.albumTitle,
                artworkURL: nil,
                plays: 0,
                lastHeard: .distantPast
            )
            actions = .history(song, player: player, play: { player.play(.history([HistorySong(song)]), from: .songs(title)) }, go: go)
        }
        actions.info = nil
        actions.playlistTracks = []
        return actions
    }
}
