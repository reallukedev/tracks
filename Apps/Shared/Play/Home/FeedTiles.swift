import SwiftUI
import TracksCore

/// A mix on the shelf: its covers, its name and why. On the Mac it lifts under the pointer
/// with Play and More over its cover, as a library cover does, and drags out as its songs.
struct MixTile: View {
    let mix: Mix
    @Environment(PlayerModel.self) private var player
    @State private var isHovered = false

    var body: some View {
        NavigationLink(value: PlayRoute.mix(mix.id)) {
            TileLabel(title: mix.kind.title, subtitle: mix.kind.tileLine) { side in
                MixCover(mix: mix, size: side)
                    .tileLift(isHovered)
            }
        }
        .buttonStyle(.pressable)
        .tileHover($isHovered, play: player.songs(in: mix).isEmpty ? nil : { play(shuffled: false) }) { menu }
        .contextMenu { menu }
        .macDraggable(SongDrag(player.songs(in: mix)))
    }

    @ViewBuilder
    private var menu: some View {
        let songs = player.songs(in: mix)
        Button("Play", systemImage: "play") { play(shuffled: false) }
        Button("Shuffle", systemImage: "shuffle") { play(shuffled: true) }
        Divider()
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
            player.enqueue(.history(songs), next: true, title: mix.kind.title)
        }
        Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") {
            player.enqueue(.history(songs), next: false, title: mix.kind.title)
        }
    }

    private func play(shuffled: Bool) {
        player.play(.history(player.songs(in: mix)), from: PlayContext(kind: .mix, title: mix.kind.title), shuffled: shuffled)
    }
}

/// A station, album or playlist on a shelf. Stations start playing; the rest open. On the Mac
/// it lifts under the pointer with Play and More over its cover, as a library cover does, and
/// drags out as its Apple Music link.
struct FeedTile: View {
    let item: FeedItem
    @Environment(PlayerModel.self) private var player
    @State private var isHovered = false

    var body: some View {
        Group {
            if let (request, context) = item.stationRequest {
                Button {
                    player.play(request, from: context)
                } label: {
                    label
                }
                .accessibilityHint("Plays the station")
            } else if let route {
                NavigationLink(value: route) { label }
            }
        }
        .buttonStyle(.pressable)
        .tileHover($isHovered, play: play) { FeedItemMenu(item: item) }
        .contextMenu { FeedItemMenu(item: item) }
        .macDraggable(url)
    }

    /// What Play over the cover does: the station, or the album or playlist from the top.
    private var play: (() -> Void)? {
        switch item.content {
        case .station, .demoStation:
            item.stationRequest.map { request, context in { player.play(request, from: context) } }
        case .album(let album):
            { player.play(.album(album), from: PlayContext(kind: .album, title: album.title)) }
        case .playlist(let playlist):
            { player.play(.playlist(playlist), from: PlayContext(kind: .playlist, title: playlist.name)) }
        }
    }

    private var url: URL? {
        switch item.content {
        case .station(let station): station.url
        case .album(let album): album.url
        case .playlist(let playlist): playlist.url
        case .demoStation: nil
        }
    }

    private var label: some View {
        TileLabel(title: item.title, subtitle: item.subtitle) { side in
            CoverImage(cover: item.cover, size: side)
                .tileLift(isHovered)
                .overlay(alignment: .topLeading) {
                    if item.isLive {
                        LiveBadge().padding(8)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if isPlayingThis {
                        NowPlayingBadge().padding(8)
                    }
                }
        }
    }

    private var isPlayingThis: Bool {
        guard item.isStation, let context = player.context, context.isStation else { return false }
        return context.title == item.title && player.hasQueue
    }

    private var route: PlayRoute? {
        switch item.content {
        case .album(let album): .album(album)
        case .playlist(let playlist): .playlist(playlist)
        case .station, .demoStation: nil
        }
    }
}

/// Everything that can be done with a station, album or playlist, for its context menu.
struct FeedItemMenu: View {
    let item: FeedItem
    @Environment(PlayerModel.self) private var player

    var body: some View {
        switch item.content {
        case .station, .demoStation:
            if let (request, context) = item.stationRequest {
                Button("Play Station", systemImage: "play") { player.play(request, from: context) }
            }
        case .album(let album):
            let context = PlayContext(kind: .album, title: album.title)
            Button("Play", systemImage: "play") { player.play(.album(album), from: context) }
            Button("Shuffle", systemImage: "shuffle") { player.play(.album(album), from: context, shuffled: true) }
            Divider()
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                player.enqueue(.album(album), next: true, title: album.title)
            }
            Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") {
                player.enqueue(.album(album), next: false, title: album.title)
            }
        case .playlist(let playlist):
            let context = PlayContext(kind: .playlist, title: playlist.name)
            Button("Play", systemImage: "play") { player.play(.playlist(playlist), from: context) }
            Button("Shuffle", systemImage: "shuffle") { player.play(.playlist(playlist), from: context, shuffled: true) }
            Divider()
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                player.enqueue(.playlist(playlist), next: true, title: playlist.name)
            }
            Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") {
                player.enqueue(.playlist(playlist), next: false, title: playlist.name)
            }
        }
    }
}

/// Bars that move while this is what's playing, as on Music's covers.
struct NowPlayingBadge: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        PlayingWaveform(isActive: player.isPlaying, color: .white)
            .font(.caption.weight(.bold))
            .frame(width: 26, height: 26)
            .background(.black.opacity(0.45), in: .circle)
            .accessibilityLabel("Now Playing")
    }
}

extension View {
    /// A shelf tile's cover rising a little under the pointer, as Music's do. Mac only.
    func tileLift(_ isHovered: Bool) -> some View {
        #if os(macOS)
        scaleEffect(isHovered ? 1.02 : 1)
            .shadow(color: .black.opacity(isHovered ? 0.18 : 0), radius: 10, y: 5)
        #else
        self
        #endif
    }

    /// Music's hover on a shelf tile: Play on the left of the cover's foot and More on the
    /// right, as ``LibraryCoverTile`` has. Nothing on iPhone, or on a tile that's disabled.
    func tileHover<Menu: View>(_ isHovered: Binding<Bool>, play: (() -> Void)?, @ViewBuilder menu: () -> Menu) -> some View {
        #if os(macOS)
        modifier(TileHover(isHovered: isHovered, play: play, menu: menu()))
        #else
        self
        #endif
    }
}

#if os(macOS)
private struct TileHover<Menu: View>: ViewModifier {
    @Binding var isHovered: Bool
    let play: (() -> Void)?
    let menu: Menu
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                // Over the cover's foot: a square as wide as the tile, the cover's place.
                if isHovered {
                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .scaleEffect(1.02)
                        .overlay(alignment: .bottom) {
                            HStack {
                                if let play {
                                    LibraryHoverPlayButton(action: play)
                                }
                                Spacer(minLength: 0)
                                LibraryHoverMoreButton { menu }
                            }
                            .padding(10)
                        }
                        .transition(.opacity)
                }
            }
            .onHover { hovering in
                withAnimation(PlayMotion.hover) { isHovered = hovering && isEnabled }
            }
            .onChange(of: isEnabled) { if !isEnabled { isHovered = false } }
    }
}
#endif
