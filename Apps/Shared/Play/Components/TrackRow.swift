import SwiftUI
import MusicKit
import TracksCore

/// Pushes a page onto the stack the view is in. Each stack that shows Apple Music content
/// sets one, so a context menu's Go to Album lands in the right place.
struct OpenPlayRouteAction: Equatable {
    /// Which stack, so two actions compare equal when they push onto the same one and views
    /// reading this aren't invalidated on every update.
    let stack: String
    let push: @MainActor (PlayRoute) -> Void

    @MainActor
    func callAsFunction(_ route: PlayRoute) {
        push(route)
    }

    /// Whether there's a stack to push onto. A menu leaves out Go to Album and the like where
    /// there isn't, rather than offering items that do nothing.
    var canPush: Bool { stack != "none" }

    /// This action, where there's a stack for it.
    var ifPushes: ((PlayRoute) -> Void)? {
        canPush ? { push($0) } : nil
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.stack == rhs.stack
    }
}

extension EnvironmentValues {
    @Entry var openPlayRoute = OpenPlayRouteAction(stack: "none") { _ in }
}

/// A song in a list: cover or track number, title, artist, and how often you've played it.
struct TrackRow: View {
    let title: String
    let subtitle: String?
    var cover: CoverArt?
    var number: Int?
    /// Your plays, from Tracks’ history. Shown when there are any.
    var plays: Int?
    var isExplicit = false
    var isCurrent = false
    /// A song of yours, for its download coming down.
    var localTrack: LocalTrack?
    /// Dimmed when it can't play: not downloaded and its server out of reach.
    var isPlayable = true
    /// A short fact in place of the plays, like when it played.
    var detail: String?

    @Environment(PlayerModel.self) private var player
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var coverSide: CGFloat = Self.cover
    @ScaledMetric(relativeTo: .body) private var numberWidth: CGFloat = 28

    // Mac rows are denser than a finger's: Music's covers there are about 40 points, and the
    // row needs no 44 point target.
    #if os(macOS)
    static let cover: CGFloat = 38
    private static let minimumHeight: CGFloat = 28
    #else
    static let cover: CGFloat = 48
    private static let minimumHeight: CGFloat = 44
    #endif

    var body: some View {
        HStack(spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        // At the largest sizes a title wraps rather than losing most of itself.
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                    if isExplicit {
                        ExplicitBadge()
                    }
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                // At the largest sizes the fact goes under the name, which needs the width.
                if let detail, plays == nil, dynamicTypeSize.isAccessibilitySize {
                    detailText(detail)
                }
            }
            // Separators start at the title, as in Music, not under the cover or number.
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            Spacer(minLength: 8)
            if let localTrack {
                DownloadStateIcon(track: localTrack)
            }
            if let plays, plays > 0 {
                Text(PlayCountText.short(plays))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityLabel(PlayCountText.spoken(plays))
            } else if let detail, !dynamicTypeSize.isAccessibilitySize {
                detailText(detail)
                    .fixedSize()
            }
        }
        .frame(minHeight: Self.minimumHeight)
        .opacity(isPlayable ? 1 : 0.45)
        .contentShape(.rect)
    }

    private func detailText(_ detail: String) -> some View {
        Text(detail)
            .font(.subheadline)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    @ViewBuilder
    private var leading: some View {
        if let cover {
            CoverImage(cover: cover, size: min(coverSide, 72))
                .overlay {
                    if isCurrent {
                        RoundedRectangle(cornerRadius: CoverImage.radius(for: min(coverSide, 72)), style: .continuous)
                            .fill(.black.opacity(0.4))
                        playingGlyph(.white)
                    }
                }
        } else if let number {
            Group {
                if isCurrent {
                    playingGlyph(.accentColor)
                } else {
                    Text(number, format: .number)
                        .font(.body)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: numberWidth)
        }
    }

    private func playingGlyph(_ color: Color) -> some View {
        PlayingWaveform(isActive: player.isPlaying, color: color)
            .font(.subheadline.weight(.semibold))
            .accessibilityLabel("Now Playing")
    }
}

/// Music's "E" for explicit songs.
struct ExplicitBadge: View {
    var body: some View {
        Text(verbatim: "E")
            .font(.caption2.weight(.bold))
            .foregroundStyle(Color.pageBackground)
            .frame(width: 14, height: 14)
            .background(.secondary, in: .rect(cornerRadius: 3, style: .continuous))
            .accessibilityLabel("Explicit")
    }
}

/// How a play count reads beside a song.
enum PlayCountText {
    /// "12 plays", short enough for the trailing edge of a row.
    static func short(_ plays: Int) -> String {
        String(AttributedString(localized: "^[\(plays) play](inflect: true)").characters)
    }

    static func spoken(_ plays: Int) -> String {
        String(AttributedString(localized: "You've played this ^[\(plays) time](inflect: true)").characters)
    }
}

extension Song {
    var isExplicit: Bool { contentRating == .explicit }
}

/// Everything that can be done with an Apple Music song, for its context menu.
struct SongMenu: View {
    let song: Song
    /// Play, where a click doesn't already play the song: on the Mac, where it selects.
    var play: (() -> Void)?
    /// Hides Go to Album on the album's own page.
    var showsAlbum = true
    var showsArtist = true
    /// Off where the menu has its own way to say no, as suggestions do, which then offer
    /// blocking after it.
    var showsSuggestLess = true

    @Environment(PlayerModel.self) private var player
    @Environment(\.openPlayRoute) private var openPlayRoute

    var body: some View {
        SongMenuItems(.catalog(
            song,
            player: player,
            play: play,
            go: openPlayRoute.ifPushes,
            showsAlbum: showsAlbum,
            showsArtist: showsArtist,
            showsSuggestLess: showsSuggestLess
        ))
    }
}

/// "Suggest Less", which keeps a song out of Tracks’ mixes. Undone from the same place.
struct SuggestLessButton: View {
    let songIdentity: String
    @Environment(PlayerModel.self) private var player

    var body: some View {
        if player.isSuggestingLess(songIdentity) {
            Button("Suggest Again", systemImage: "hand.thumbsup") {
                player.setSuggestLess(songIdentity, false)
            }
        } else {
            Button("Suggest Less", systemImage: "hand.thumbsdown") {
                player.setSuggestLess(songIdentity, true)
            }
        }
    }
}

/// "Block", which stops Tracks playing or suggesting an artist anywhere, on every device.
/// Undone from the same place, or from Blocked Artists in Settings.
struct BlockArtistButton: View {
    /// The artist, as their page names them.
    let artist: String
    /// Whether the name goes in the item: on a song's menu it says whose; on the artist's
    /// own page it goes without saying.
    var namesArtist = true
    @Environment(PlayerModel.self) private var player

    /// For a song's menu: whoever it's by, before anyone featured.
    init(songBy credit: String) {
        artist = BlockedArtists.leadArtist(of: credit)
    }

    init(artist: String, namesArtist: Bool = false) {
        self.artist = artist
        self.namesArtist = namesArtist
    }

    var body: some View {
        if !artist.isEmpty {
            if player.isBlocked(artist: artist) {
                Button(namesArtist ? "Unblock \(artist)" : "Unblock Artist", systemImage: "person.crop.circle.badge.checkmark") {
                    player.unblock(artist: artist)
                }
            } else {
                Button(namesArtist ? "Block \(artist)" : "Block Artist", systemImage: "person.crop.circle.badge.xmark", role: .destructive) {
                    player.block(artist: artist)
                }
            }
        }
    }
}

/// A history song's menu: the same actions, for a song known by id and name.
struct HistorySongMenu: View {
    let song: MixSong
    /// Play, where a click doesn't already play the song.
    var play: (() -> Void)?
    @Environment(PlayerModel.self) private var player
    @Environment(\.openPlayRoute) private var openPlayRoute

    var body: some View {
        SongMenuItems(.history(song, player: player, play: play, go: openPlayRoute.ifPushes))
    }
}

/// The album and artist a song belongs to, looked up when asked for.
enum SongLinks {
    static func album(of song: Song) async -> Album? {
        if let album = song.albums?.first { return album }
        return try? await song.with([.albums]).albums?.first
    }

    static func artist(of song: Song) async -> Artist? {
        if let artist = song.artists?.first { return artist }
        return try? await song.with([.artists]).artists?.first
    }
}
