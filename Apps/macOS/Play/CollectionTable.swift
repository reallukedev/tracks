import SwiftUI
import UniformTypeIdentifiers

/// A song in a collection's table on the Mac, whichever kind of song it is underneath.
struct CollectionTrack: Identifiable, Hashable {
    /// Unique in the collection, so a playlist can hold a song twice.
    let id: String
    /// Its place in the collection, from 1: the order the collection itself gives.
    let position: Int
    /// The track number on an album, or the position.
    let number: Int
    let title: String
    let artist: String
    let album: String
    /// Your plays, from Tracks’ history, for a column that's hidden until asked for.
    let plays: Int
    let duration: TimeInterval
    var isExplicit = false
    var isCurrent = false
    var isPlayable = true
    /// Why it can't play, or what's happening to it, for the end of its title.
    var status: String?
    /// The song's own cover, on a playlist or mix, where songs come from many albums.
    var artwork: CoverArt?
    /// How to find the song again, for dragging it onto Up Next or into another app.
    var drag: SongDrag.Song?
}

/// The Mac collection page: the header, and the songs under it, scrolling as one page as
/// Music's do. The rows are lazy, so a playlist of hundreds lays out only what's on screen.
struct CollectionMacLayout<Header: View, Content: View>: View {
    /// Kept for the pages that say so; the page scrolls, so a description never crowds it.
    var hasNote = false
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                content
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.bottom, 28)
            }
        }
        .background(Color.pageBackground)
        // The glow runs on under the bar, as Music's headers do.
        .headerUnderBar()
        #if DEBUG
        .task { CollectionScreenshotSetup.apply() }
        #endif
    }
}

#if DEBUG
/// For screenshots of collection pages, which a launch argument can't otherwise give:
/// `-TracksAppearance dark` draws the app dark whatever the system's set to, and
/// `-TracksWindowSize 900x640` sizes the window. Debug builds only.
enum CollectionScreenshotSetup {
    @MainActor private static var hasApplied = false

    @MainActor
    static func apply() {
        guard !hasApplied else { return }
        hasApplied = true
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "TracksAppearance") == "dark" {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        if let size = defaults.string(forKey: "TracksWindowSize")?.split(separator: "x").compactMap({ Double($0) }),
           size.count == 2, let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
            window.setContentSize(NSSize(width: size[0], height: size[1]))
        }
    }
}
#endif

/// A collection's songs on the Mac, as Music lists a playlist: a row for each, with its
/// place, its cover on a playlist, its title, artist and album, and its length. A click
/// selects (⌘ and ⇧ add to it), a double-click or Return plays from that song, a right-click
/// shows its menu, and the arrow keys move through the list. Several selected can be queued
/// or removed together.
///
/// No column headers or stripes: the list reads as the music, and your plays of it live on
/// the song's own page.
struct CollectionTable<SongMenu: View>: View {
    enum Style {
        /// Track numbers, the album's order, and an artist column only for songs by others.
        case album
        /// Positions, covers, and the album each song is from.
        case list
    }

    let tracks: [CollectionTrack]
    var style = Style.list
    /// Plays from a song, by its id.
    let play: (CollectionTrack.ID) -> Void
    /// Adds songs to Up Next, next or last, in the order given.
    let enqueue: ([CollectionTrack.ID], _ next: Bool) -> Void
    /// Takes songs out of the collection, for a playlist of your own. Delete asks first.
    var removal: Removal?
    /// Moves songs to a place among the rest, for a playlist you order yourself.
    var move: ((_ ids: [CollectionTrack.ID], _ destination: Int) -> Void)?
    /// The last row came into view: time to load more, for a long playlist that loads in pages.
    var onReachEnd: (() -> Void)?
    /// One song's own menu.
    @ViewBuilder let menu: (CollectionTrack) -> SongMenu

    struct Removal {
        /// The collection's name, for the confirmation.
        let collection: String
        let remove: (Set<CollectionTrack.ID>) -> Void
    }

    @State private var selection = Set<CollectionTrack.ID>()
    /// Where a ⇧-click extends the selection from.
    @State private var anchor: CollectionTrack.ID?
    /// The end of the selection ⇧ and an arrow moves, the other end from the anchor.
    @State private var head: CollectionTrack.ID?
    @State private var removing: Set<CollectionTrack.ID>?
    @State private var width: CGFloat = 0
    @FocusState private var isFocused: Bool

    /// Only where some song isn't by the collection's main artist: on a playlist or mix, or a
    /// compilation.
    private var showsArtist: Bool {
        style == .list || Set(tracks.map { $0.artist.lowercased() }).count > 1
    }

    private var showsAlbum: Bool { style == .list && width > 720 }

    private var showsCovers: Bool { style == .list && tracks.contains { $0.artwork != nil } }

    /// A mix knows its songs by name, not their lengths.
    private var showsTime: Bool {
        tracks.contains { $0.duration > 0 }
    }

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(tracks.enumerated(), id: \.element.id) { index, track in
                row(track, index: index)
            }
        }
        .padding(.horizontal, PlayMetrics.margin - 10)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        // ⇧ with an arrow extends the selection from where it started, as in Finder.
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            let by = press.key == .upArrow ? -1 : 1
            if press.modifiers.contains(.shift) { extend(by) } else { step(by) }
            return .handled
        }
        // Edit › Select All, ⌘A.
        .onCommand(#selector(NSResponder.selectAll(_:))) {
            selection = Set(tracks.map(\.id))
        }
        .onKeyPress(.return) {
            if let first = tracks.first(where: { selection.contains($0.id) && $0.isPlayable }) { play(first.id) }
            return .handled
        }
        .onKeyPress(.escape) {
            selection = []
            return .handled
        }
        .onDeleteCommand {
            guard removal != nil, !selection.isEmpty else { return }
            removing = selection
        }
        .confirmationDialog(
            removalTitle,
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button(removing.map { $0.count == 1 ? String(localized: "Remove Song") : String(localized: "Remove Songs") } ?? "", role: .destructive) {
                if let removing, let removal {
                    removal.remove(removing)
                    selection.subtract(removing)
                }
            }
        } message: {
            Text("They stay in your music, and your plays of them stay in your history.")
        }
    }

    private func row(_ track: CollectionTrack, index: Int) -> some View {
        CollectionSongRow(
            track: track,
            isSelected: selection.contains(track.id),
            isFocused: isFocused,
            showsCover: showsCovers,
            showsArtist: showsArtist,
            showsAlbum: showsAlbum,
            showsTime: showsTime,
            isLast: index == tracks.count - 1,
            play: { play(track.id) }
        )
        .onTapGesture { click(track) }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if track.isPlayable { play(track.id) }
        })
        // VoiceOver's press selects, as a click does; Play stays a named action on the row.
        .accessibilityAction {
            isFocused = true
            selection = [track.id]
            anchor = track.id
        }
        .contextMenu {
            if selection.contains(track.id), selection.count > 1 {
                selectionMenu(selection)
            } else {
                // A click selects here, so Play leads the song's menu.
                if track.isPlayable {
                    Button("Play", systemImage: "play") { play(track.id) }
                }
                menu(track)
                if removal != nil {
                    Divider()
                    Button("Remove from Playlist", systemImage: "minus.circle", role: .destructive) { removing = [track.id] }
                }
            }
        }
        .draggable(drag(from: track))
        .modifier(RowReordering(index: index, move: move))
        .onAppear {
            if track.id == tracks.last?.id { onReachEnd?() }
        }
    }

    /// The row dragged, with the rest of the selection when it's part of it, in the
    /// collection's order.
    private func drag(from track: CollectionTrack) -> CollectionRowDrag {
        let dragged = selection.contains(track.id) ? tracks.filter { selection.contains($0.id) } : [track]
        return CollectionRowDrag(ids: dragged.map(\.id), songs: SongDrag(songs: dragged.compactMap(\.drag)))
    }

    // MARK: Selecting

    private func click(_ track: CollectionTrack) {
        isFocused = true
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(track.id) { selection.remove(track.id) } else { selection.insert(track.id) }
            anchor = track.id
            head = track.id
        } else if flags.contains(.shift), let anchor,
                  let from = tracks.firstIndex(where: { $0.id == anchor }),
                  let to = tracks.firstIndex(where: { $0.id == track.id }) {
            selection = Set(tracks[min(from, to)...max(from, to)].map(\.id))
            head = track.id
        } else {
            selection = [track.id]
            anchor = track.id
            head = track.id
        }
    }

    private func step(_ by: Int) {
        let current = tracks.lastIndex { selection.contains($0.id) } ?? (by > 0 ? -1 : tracks.count)
        let next = min(max(0, current + by), tracks.count - 1)
        guard tracks.indices.contains(next) else { return }
        selection = [tracks[next].id]
        anchor = tracks[next].id
        head = tracks[next].id
    }

    private func extend(_ by: Int) {
        guard let anchor, let from = tracks.firstIndex(where: { $0.id == anchor }) else {
            step(by)
            return
        }
        let current = head.flatMap { head in tracks.firstIndex { $0.id == head } } ?? from
        let next = min(max(0, current + by), tracks.count - 1)
        head = tracks[next].id
        selection = Set(tracks[min(from, next)...max(from, next)].map(\.id))
    }

    // MARK: Menus

    @ViewBuilder
    private func selectionMenu(_ ids: Set<CollectionTrack.ID>) -> some View {
        let ordered = tracks.filter { ids.contains($0.id) && $0.isPlayable }.map(\.id)
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { enqueue(ordered, true) }
            .disabled(ordered.isEmpty)
        Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") { enqueue(ordered, false) }
            .disabled(ordered.isEmpty)
        if removal != nil {
            Divider()
            Button("Remove \(ids.count) Songs from Playlist", systemImage: "minus.circle", role: .destructive) { removing = ids }
        }
    }

    private var removalTitle: String {
        guard let removing, let removal else { return "" }
        let songs = String(AttributedString(localized: "^[\(removing.count) Song](inflect: true)").characters)
        return String(localized: "Remove \(songs) from \u{201C}\(removal.collection)\u{201D}?")
    }
}

/// Takes rows dropped on a row to its place, for a playlist you order yourself.
private struct RowReordering: ViewModifier {
    let index: Int
    let move: ((_ ids: [CollectionTrack.ID], _ destination: Int) -> Void)?

    func body(content: Content) -> some View {
        if let move {
            content
                .dropDestination(for: CollectionRowDrag.self) { drops, _ in
                    let ids = drops.flatMap(\.ids)
                    guard !ids.isEmpty else { return false }
                    move(ids, index)
                    return true
                }
        } else {
            content
        }
    }
}

/// One song of a collection.
private struct CollectionSongRow: View {
    let track: CollectionTrack
    let isSelected: Bool
    let isFocused: Bool
    let showsCover: Bool
    let showsArtist: Bool
    let showsAlbum: Bool
    let showsTime: Bool
    let isLast: Bool
    let play: () -> Void

    @State private var isHovered = false
    @Environment(PlayerModel.self) private var player

    private var height: CGFloat { showsCover ? 54 : 40 }

    var body: some View {
        HStack(spacing: 12) {
            number
                .frame(width: 26, alignment: .trailing)
            if showsCover {
                CoverImage(cover: track.artwork ?? .url(nil, seed: track.album.isEmpty ? track.title : track.album), size: 40)
                    .overlay {
                        // As in Music: under the pointer, Play sits over the cover.
                        if isHovered, track.isPlayable {
                            Button(action: play) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: CoverImage.radius(for: 40), style: .continuous)
                                        .fill(.black.opacity(0.4))
                                    Image(systemName: "play.fill")
                                        .font(.callout.weight(.bold))
                                        .foregroundStyle(.white)
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .help("Play \(track.title)")
                            .transition(.opacity)
                        }
                    }
            }
            HStack(spacing: 6) {
                Text(track.title)
                    .foregroundStyle(track.isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .fontWeight(track.isCurrent ? .semibold : .regular)
                    .lineLimit(1)
                if track.isExplicit {
                    ExplicitBadge()
                }
                if let status = track.status {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsArtist {
                ArtistLinks(artist: track.artist, title: track.title, linkStyle: .cell)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if showsAlbum {
                Text(track.album)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if showsTime {
                Text(track.duration > 0 ? Duration.seconds(track.duration).formatted(.time(pattern: .minuteSecond)) : "")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: height)
        .opacity(track.isPlayable ? 1 : 0.45)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(background)
        }
        .overlay(alignment: .bottom) {
            if !isLast, !isSelected, !isHovered {
                Divider()
                    .padding(.leading, showsCover ? 10 + 26 + 12 + 40 + 12 : 10 + 26 + 12)
                    .padding(.trailing, 10)
            }
        }
        .contentShape(.rect)
        .onHover { hovering in
            withAnimation(PlayMotion.hover) { isHovered = hovering }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Play") { play() }
    }

    private var background: AnyShapeStyle {
        if isSelected {
            return AnyShapeStyle(.primary.opacity(isFocused ? 0.13 : 0.08))
        }
        return AnyShapeStyle(.quaternary.opacity(isHovered ? 0.6 : 0))
    }

    /// The place, Play under the pointer where there's no cover to hold it, or a waveform
    /// while it plays.
    @ViewBuilder
    private var number: some View {
        if isHovered, track.isPlayable, !showsCover {
            Button(action: play) {
                Image(systemName: "play.fill")
                    .font(.callout)
                    .foregroundStyle(.tint)
                    .frame(width: 26, height: 26)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Play \(track.title)")
        } else if track.isCurrent {
            PlayingWaveform(isActive: player.isPlaying)
                .font(.callout.weight(.semibold))
                .accessibilityLabel("Now Playing")
        } else {
            Text(track.number, format: .number)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

/// What a row carries when it's dragged: its place in the collection, for moving it within
/// its playlist, and the songs themselves, for Up Next and other apps.
nonisolated struct CollectionRowDrag: Codable, Transferable {
    let ids: [String]
    let songs: SongDrag

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .tracksCollectionRows)
        ProxyRepresentation { (drag: CollectionRowDrag) in drag.songs }
            .exportingCondition { !$0.songs.songs.isEmpty }
    }
}

extension UTType {
    /// Rows dragged within one of Tracks’ collections. Declared in the Mac app's Info.plist.
    nonisolated static let tracksCollectionRows = UTType(exportedAs: "com.luke.tracks.collection-rows")
}
