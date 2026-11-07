import SwiftUI
import MusicKit
import TracksCore

// MARK: - Choosing the party

/// The kinds of party, as chips on the field: the chosen one white with the party's colour
/// for its words, the rest a veil of white. Scrolls to keep the chosen one in view.
struct PartyVibeChips: View {
    @Binding var selection: PartyVibe
    let vibes: [PartyVibe]
    @ScaledMetric(relativeTo: .subheadline) private var chipHeight: CGFloat = 36
    /// Counts picks, so the haptic answers a tap and nothing else.
    @State private var picks = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(vibes) { vibe in
                        chip(vibe)
                            .id(vibe)
                    }
                }
            }
            .contentMargins(.horizontal, PlayMetrics.margin, for: .scrollContent)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
            .onChange(of: selection) { _, chosen in
                withAnimation(PlayMotion.panel) { proxy.scrollTo(chosen, anchor: .center) }
            }
        }
        .sensoryFeedback(.selection, trigger: picks)
    }

    private func chip(_ vibe: PartyVibe) -> some View {
        let isSelected = vibe == selection
        return Button {
            guard vibe != selection else { return }
            picks += 1
            selection = vibe
        } label: {
            Label(vibe.title, systemImage: vibe.symbol)
                .labelStyle(.titleAndIcon)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(isSelected ? vibe.color : .white)
                .padding(.horizontal, 14)
                .frame(height: chipHeight)
                .background(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.18)), in: .capsule)
                // A finger's worth to tap, however slim the chip draws.
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(vibe.tagline)
    }
}

// MARK: - Playing a playlist

enum PartyPlayback {
    /// What to hand the player for a playlist. With sample data the player can't play Apple
    /// Music, so it plays the invented playlist's songs by name.
    static func request(for playlist: Playlist, isDemo: Bool) -> PlayRequest {
        #if DEBUG
        if isDemo, let tracks = playlist.tracks {
            return .history(tracks.map { HistorySong(songID: "", title: $0.title, artistName: $0.artistName, albumTitle: $0.albumTitle) })
        }
        #endif
        return .playlist(playlist)
    }

    static func play(_ playlist: Playlist, player: PlayerModel, shuffled: Bool = false) {
        player.play(request(for: playlist, isDemo: player.isDemo), from: PlayContext(kind: .playlist, title: playlist.name), shuffled: shuffled)
    }
}

/// Everything that can be done with a party playlist, for its context menu.
struct PartyPlaylistMenu: View {
    let playlist: Playlist
    @Environment(PlayerModel.self) private var player

    var body: some View {
        let request = PartyPlayback.request(for: playlist, isDemo: player.isDemo)
        Button("Play", systemImage: "play") { PartyPlayback.play(playlist, player: player) }
        Button("Shuffle", systemImage: "shuffle") { PartyPlayback.play(playlist, player: player, shuffled: true) }
        Divider()
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
            player.enqueue(request, next: true, title: playlist.name)
        }
        Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") {
            player.enqueue(request, next: false, title: playlist.name)
        }
        Divider()
        Button("Add to Library", systemImage: "plus") { player.addToLibrary(playlist) }
            .disabled(player.isDemo)
    }
}

// MARK: - Top Pick

/// The playlist to start with, as the App Store's Today card leads with one story: its cover
/// large, Apple Music's words on it, and Play right there. The card opens the playlist.
struct PartyTopPick: View {
    let playlist: Playlist
    let vibe: PartyVibe
    @Environment(PlayerModel.self) private var player
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        content
            .padding(PartyMetrics.cardPadding)
            .frame(maxWidth: PartyMetrics.topPickWidth, alignment: .leading)
            .background(Color.cardFill, in: .rect(cornerRadius: PartyMetrics.cardRadius, style: .continuous))
            .contextMenu { PartyPlaylistMenu(playlist: playlist) }
    }

    private var cover: CoverArt {
        playlist.artwork.map(CoverArt.artwork) ?? .url(nil, seed: playlist.name)
    }

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        HStack(alignment: .top, spacing: 20) {
            NavigationLink(value: PlayRoute.playlist(playlist)) {
                CoverImage(cover: cover, size: 180)
            }
            .buttonStyle(.pressable)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 14) {
                NavigationLink(value: PlayRoute.playlist(playlist)) {
                    words(noteLines: 5)
                }
                .buttonStyle(.pressable)
                buttons
                    .fixedSize()
            }
        }
        #else
        VStack(alignment: .leading, spacing: 16) {
            NavigationLink(value: PlayRoute.playlist(playlist)) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 14) {
                        CoverImage(cover: cover, size: 200)
                        words(noteLines: nil)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 14) {
                            CoverImage(cover: cover, size: 120)
                            heading
                        }
                        noteText(lines: 4)
                    }
                }
            }
            .buttonStyle(.pressable)
            buttons
        }
        #endif
    }

    /// "Top Pick", the name and who made it.
    private var heading: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Top Pick")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Text(playlist.name)
                .font(.title3.bold())
                .foregroundStyle(.primary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
            if let curator = playlist.curatorName {
                Text(curator)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func words(noteLines: Int?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            heading
            noteText(lines: noteLines)
        }
    }

    @ViewBuilder
    private func noteText(lines: Int?) -> some View {
        if let note = playlist.partyNote {
            Text(note)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(lines)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var buttons: some View {
        PartyPlayButtons(tint: vibe.palette[1]) {
            PartyPlayback.play(playlist, player: player)
        } shuffle: {
            PartyPlayback.play(playlist, player: player, shuffled: true)
        }
    }
}

/// Play and Shuffle for a card: Play in the party's colour, Shuffle quiet beside it. The same
/// width on iPhone, filling the card; their own width on the Mac.
struct PartyPlayButtons: View {
    let tint: Color
    var canPlay = true
    let play: () -> Void
    let shuffle: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        layout {
            Button(action: play) {
                Label("Play", systemImage: "play.fill")
                    .frame(maxWidth: PartyMetrics.fillsButtons ? .infinity : nil)
            }
            .buttonStyle(.glassProminent)
            .tint(tint)
            Button(action: shuffle) {
                Label("Shuffle", systemImage: "shuffle")
                    .frame(maxWidth: PartyMetrics.fillsButtons ? .infinity : nil)
            }
            .buttonStyle(.glass)
            .tint(.primary)
        }
        .font(PartyMetrics.buttonFont)
        .lineLimit(1)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .disabled(!canPlay)
    }
}

// MARK: - Grids

/// A playlist in the grid: its cover, its name over two lines at most, and who made it.
struct PartyPlaylistTile: View {
    let playlist: Playlist

    var body: some View {
        NavigationLink(value: PlayRoute.playlist(playlist)) {
            PartyTileLabel(title: playlist.name, subtitle: playlist.curatorName) { side in
                CoverImage(cover: playlist.artwork.map(CoverArt.artwork) ?? .url(nil, seed: playlist.name), size: side)
            }
        }
        .buttonStyle(.pressable)
        .contextMenu { PartyPlaylistMenu(playlist: playlist) }
    }
}

/// A square cover filling its column, with a title and a line under it.
struct PartyTileLabel<Cover: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var cover: (CGFloat) -> Cover

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    GeometryReader { proxy in
                        cover(proxy.size.width)
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// The grid's columns: two on iPhone, one at accessibility sizes, as many as fit on the Mac.
struct PartyGrid<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            content
        }
    }

    private var columns: [GridItem] {
        #if os(macOS)
        [GridItem(.adaptive(minimum: 180), spacing: PlayMetrics.shelfSpacing, alignment: .top)]
        #else
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible(), alignment: .top)]
            : Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 2)
        #endif
    }
}

// MARK: - Loading

/// The shape of the Top Pick while it's found: the cover, the words and the buttons, in the
/// places they'll be.
struct PartyTopPickPlaceholder: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            #if os(macOS)
            HStack(alignment: .top, spacing: 20) {
                block(width: 180, height: 180, radius: CoverImage.radius(for: 180))
                VStack(alignment: .leading, spacing: 10) {
                    lines
                    block(width: 190, height: 34, radius: 17)
                        .padding(.top, 4)
                }
            }
            #else
            if dynamicTypeSize.isAccessibilitySize {
                block(width: 200, height: 200, radius: CoverImage.radius(for: 200))
                lines
            } else {
                HStack(alignment: .top, spacing: 14) {
                    block(width: 120, height: 120, radius: CoverImage.radius(for: 120))
                    lines
                }
            }
            block(width: nil, height: 50, radius: 25)
            #endif
        }
        .padding(PartyMetrics.cardPadding)
        .frame(maxWidth: PartyMetrics.topPickWidth, alignment: .leading)
        .background(Color.cardFill, in: .rect(cornerRadius: PartyMetrics.cardRadius, style: .continuous))
        .accessibilityHidden(true)
    }

    private var lines: some View {
        VStack(alignment: .leading, spacing: 8) {
            block(width: 60, height: 10, radius: 3)
            block(width: 150, height: 18, radius: 4)
            block(width: 90, height: 12, radius: 3)
        }
        .padding(.top, 2)
    }

    private func block(width: CGFloat?, height: CGFloat, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.placeholderFill)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
    }
}

/// A tile's shape while playlists are found: a square and two lines, sized as the tiles are.
struct PartyTilePlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: CoverImage.maximumRadius, style: .continuous)
                .fill(Color.placeholderFill)
                .aspectRatio(1, contentMode: .fit)
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(Color.placeholderFill).frame(width: 110, height: 11)
                Capsule().fill(Color.placeholderFill).frame(width: 70, height: 9)
            }
            .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }
}

// MARK: - Metrics

enum PartyMetrics {
    static let cardRadius: CGFloat = 22
    /// Your Party Mix's songs listed at first, and with Show More.
    static let mixCollapsed = 5
    static let mixExpanded = 25
    #if os(macOS)
    static let cardPadding: CGFloat = 20
    static let topPickWidth: CGFloat = 720
    static let fillsButtons = false
    static let buttonFont = Font.body.weight(.semibold)
    static let heroTop: CGFloat = 28
    #else
    static let cardPadding: CGFloat = 16
    static let topPickWidth: CGFloat = .infinity
    static let fillsButtons = true
    static let buttonFont = Font.headline
    static let heroTop: CGFloat = 12
    #endif
}
