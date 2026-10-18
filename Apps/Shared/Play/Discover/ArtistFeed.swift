import SwiftUI
import MusicKit
import TracksCore

/// Find Artists as the App Store's Today tab tells stories: a feed of cards, each a different
/// way in. One artist, full bleed, and why they're here. A handful to try if you like one of
/// yours. One song to start someone with. A genre to go deeper into. The kinds take turns, so
/// the page keeps changing as it goes down, and it goes on for as long as you scroll.
struct ArtistFeed: View {
    let artists: [SuggestedArtist]

    @State private var width: CGFloat = 0

    var body: some View {
        let cards = Self.cards(from: artists)
        Group {
            if width >= Self.pairedWidth {
                // As the Today tab pairs its stories: a wide card and a narrow one, then the
                // other way round, so no two rows look alike.
                let rows = stride(from: 0, to: cards.count, by: 2).map { Array(cards[$0..<min($0 + 2, cards.count)]) }
                LazyVStack(spacing: Self.spacing) {
                    ForEach(rows.enumerated(), id: \.element.first?.id) { index, row in
                        PairedRow(wideFirst: index.isMultiple(of: 2), spacing: Self.spacing) {
                            ForEach(row) { card in
                                FeedCardView(card: card)
                            }
                        }
                        .frame(height: Self.cardHeight)
                        .transition(.opacity)
                    }
                }
            } else {
                LazyVStack(spacing: Self.spacing) {
                    ForEach(cards) { card in
                        FeedCardView(card: card)
                            .frame(height: Self.cardHeight)
                            .transition(.opacity)
                    }
                }
            }
        }
        .frame(maxWidth: Self.maximumWidth)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PlayMetrics.margin)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    /// Wide enough to pair cards; narrower, one to a row.
    private static let pairedWidth: CGFloat = 760
    /// On an ultra-wide window the cards stop growing, as a magazine's page would.
    private static let maximumWidth: CGFloat = 1_400

    #if os(macOS)
    nonisolated static let cardHeight: CGFloat = 440
    private static let spacing: CGFloat = 24
    #else
    nonisolated static let cardHeight: CGFloat = 420
    private static let spacing: CGFloat = 20
    #endif

    // MARK: - Composing the feed

    enum Card: Identifiable {
        case feature(SuggestedArtist)
        case list(seed: String, [SuggestedArtist])
        case song(SuggestedArtist)
        case genre(String, [SuggestedArtist])

        var id: String {
            switch self {
            case .feature(let artist): "feature.\(artist.id.rawValue)"
            case .list(let seed, let artists): "list.\(seed).\(artists.first?.id.rawValue ?? "")"
            case .song(let artist): "song.\(artist.id.rawValue)"
            case .genre(let genre, let artists): "genre.\(genre).\(artists.first?.id.rawValue ?? "")"
            }
        }
    }

    private enum Slot: CaseIterable { case feature, list, song, genre }

    /// The artists dealt into cards, each artist once: the kinds in turn, a card of a kind
    /// only when there are artists enough for it, and the best matches first.
    static func cards(from artists: [SuggestedArtist]) -> [Card] {
        var remaining = artists
        var cards: [Card] = []
        var turn = 0
        while !remaining.isEmpty {
            let slot = Slot.allCases[turn % Slot.allCases.count]
            turn += 1
            switch slot {
            case .feature:
                cards.append(.feature(remaining.removeFirst()))
            case .song:
                cards.append(.song(remaining.removeFirst()))
            case .list:
                let bySeed = Dictionary(grouping: remaining) { $0.because.first ?? "" }
                guard let (seed, group) = bySeed.filter({ !$0.key.isEmpty && $0.value.count >= 3 }).max(by: { $0.value.count < $1.value.count }) else { continue }
                let chosen = Array(group.prefix(4))
                remaining.removeAll { artist in chosen.contains { $0.id == artist.id } }
                cards.append(.list(seed: seed, chosen))
            case .genre:
                let byGenre = Dictionary(grouping: remaining) { $0.genre ?? "" }
                guard let (genre, group) = byGenre.filter({ !$0.key.isEmpty && $0.value.count >= 3 }).max(by: { $0.value.count < $1.value.count }) else { continue }
                let chosen = Array(group.prefix(5))
                remaining.removeAll { artist in chosen.contains { $0.id == artist.id } }
                cards.append(.genre(genre, chosen))
            }
        }
        return cards
    }
}

// MARK: - Cards

private struct FeedCardView: View {
    let card: ArtistFeed.Card
    @State private var isHovered = false

    var body: some View {
        Group {
            switch card {
            case .feature(let artist): FeatureCard(suggestion: artist)
            case .list(let seed, let artists): ListCard(seed: seed, artists: artists)
            case .song(let artist): SongCard(suggestion: artist)
            case .genre(let genre, let artists): GenreCard(genre: genre, artists: artists)
            }
        }
        .clipShape(.rect(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(isHovered ? 0.22 : 0.12), radius: isHovered ? 22 : 14, y: isHovered ? 12 : 7)
        .scaleEffect(isHovered ? 1.008 : 1)
        .onHover { hovering in
            withAnimation(PlayMotion.hover) { isHovered = hovering }
        }
    }
}

/// Where a card's words sit over a picture: white, with the picture darkened under them.
private struct Scrim: View {
    var body: some View {
        LinearGradient(
            stops: [.init(color: .clear, location: 0.35), .init(color: .black.opacity(0.78), location: 1)],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }
}

/// A picture that fills its card, cropped to it.
private struct FillPicture: View {
    let cover: CoverArt

    var body: some View {
        Color.clear
            .overlay {
                GeometryReader { proxy in
                    let side = max(proxy.size.width, proxy.size.height)
                    CoverImage(cover: cover, size: side, isBare: true)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .clipped()
    }
}

/// Eyebrow, headline and a line, in white, as the Today tab sets a story.
private struct CardWords: View {
    let eyebrow: String
    let title: String
    var line: String?
    @ScaledMetric(relativeTo: .title) private var titleSize: CGFloat = CardWords.baseTitleSize

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(eyebrow)
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .kerning(0.5)
                .foregroundStyle(.white.opacity(0.75))
            Text(title)
                .font(.system(size: titleSize, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            if let line {
                Text(line)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(2)
            }
        }
        .allowsHitTesting(false)
    }

    #if os(macOS)
    private static let baseTitleSize: CGFloat = 32
    #else
    private static let baseTitleSize: CGFloat = 28
    #endif
}

/// A white capsule on a picture: the card's one call.
private struct CardButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(minHeight: 34)
                .foregroundStyle(.black)
                .background(.white, in: .capsule)
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.pressable)
    }
}

// MARK: Feature

/// One artist, full bleed: who they are and who of yours led here.
private struct FeatureCard: View {
    let suggestion: SuggestedArtist
    @Environment(PlayerModel.self) private var player
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            NavigationLink(value: PlayRoute.artist(suggestion.artist)) {
                FillPicture(cover: suggestion.artist.artwork.map(CoverArt.artwork) ?? .url(nil, seed: suggestion.artist.name))
                    .overlay { Scrim() }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(suggestion.artist.name)
            .accessibilityHint("Opens their page")

            VStack(alignment: .leading, spacing: 14) {
                CardWords(
                    eyebrow: String(localized: "Because you like \(suggestion.because.first ?? "")"),
                    title: suggestion.artist.name,
                    line: suggestion.genre
                )
                HStack(spacing: 10) {
                    if model.musicSource == .appleMusic {
                        CardButton(title: "Play", systemImage: "play.fill") {
                            Task { await ArtistPlayback.playTopSongs(of: suggestion.artist, player: player) }
                        }
                    }
                    Menu {
                        SuggestedArtistMenu(suggestion: suggestion)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(.white.opacity(0.22), in: .circle)
                            .frame(width: 44, height: 44)
                            .contentShape(.circle)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("More")
                }
            }
            .padding(24)
        }
        .contextMenu { SuggestedArtistMenu(suggestion: suggestion) }
    }
}

// MARK: List

/// A few to try if you like one of yours, each playable from its row.
private struct ListCard: View {
    let seed: String
    let artists: [SuggestedArtist]
    @Environment(PlayerModel.self) private var player
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(String(AttributedString(localized: "^[\(artists.count) artist](inflect: true) to try").characters))
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .kerning(0.5)
                    .foregroundStyle(.tint)
                Text("If You Like \(seed)")
                    .font(.title2.bold())
                    .lineLimit(2)
            }
            .padding(.bottom, 12)

            ForEach(artists.enumerated(), id: \.element.id) { index, artist in
                if index > 0 {
                    Divider().padding(.leading, 64)
                }
                HStack(spacing: 12) {
                    NavigationLink(value: PlayRoute.artist(artist.artist)) {
                        HStack(spacing: 12) {
                            CoverImage(cover: artist.artist.artwork.map(CoverArt.artwork) ?? .url(nil, seed: artist.artist.name), size: 52, isCircle: true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(artist.artist.name)
                                    .font(.headline)
                                    .lineLimit(1)
                                Text(artist.genre ?? "")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    if model.musicSource == .appleMusic {
                        Button {
                            Task { await ArtistPlayback.playTopSongs(of: artist.artist, player: player) }
                        } label: {
                            Text("Play")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 5)
                                .frame(minHeight: 28)
                                .background(.quaternary, in: .capsule)
                                .frame(minHeight: 44)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.pressable)
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Play \(artist.artist.name)")
                    }
                }
                .padding(.vertical, 9)
                .contextMenu { SuggestedArtistMenu(suggestion: artist) }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.cardFill)
    }
}

// MARK: Song

/// One song to meet someone by, large, on its cover's colour.
private struct SongCard: View {
    let suggestion: SuggestedArtist
    @Environment(PlayerModel.self) private var player
    @State private var song: Song?
    @State private var tint: Color?

    private var cover: CoverArt {
        song?.artwork.map(CoverArt.artwork)
            ?? suggestion.artist.artwork.map(CoverArt.artwork)
            ?? .url(nil, seed: suggestion.artist.name)
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            Button(action: play) {
                CoverImage(cover: cover, size: Self.side)
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(Text("Play \(song?.title ?? suggestion.artist.name)"))
            VStack(spacing: 3) {
                Text("Start with This")
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .kerning(0.5)
                    .foregroundStyle(.white.opacity(0.75))
                Text(song?.title ?? suggestion.artist.name)
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                NavigationLink(value: PlayRoute.artist(suggestion.artist)) {
                    Text(song == nil ? String(localized: "Their best songs") : String(localized: "by \(suggestion.artist.name)"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .underline()
                }
                .buttonStyle(.plain)
            }
            .multilineTextAlignment(.center)
            CardButton(title: "Play", systemImage: "play.fill", action: play)
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            LinearGradient(colors: [tint ?? CoverStage.fallback, (tint ?? CoverStage.fallback).mix(with: .black, by: 0.4)], startPoint: .top, endPoint: .bottom)
                .animation(PlayMotion.tint, value: tint)
        }
        .coverTint(of: cover, into: $tint)
        .task(id: suggestion.id) {
            let top = try? await suggestion.artist.with([.topSongs]).topSongs
            guard !Task.isCancelled else { return }
            song = top.flatMap { PlayPreferences.versions(of: Array($0.prefix(5))).first }
        }
        .contextMenu {
            if let song { SongMenu(song: song) }
            SuggestedArtistMenu(suggestion: suggestion)
        }
    }

    /// The song, or their best songs until it's found.
    private func play() {
        if let song {
            player.play(.songs([song]), from: PlayContext(kind: .artist, title: suggestion.artist.name))
        } else {
            Task { await ArtistPlayback.playTopSongs(of: suggestion.artist, player: player) }
        }
    }

    #if os(macOS)
    private static let side: CGFloat = 200
    #else
    private static let side: CGFloat = 180
    #endif
}

// MARK: Genre

/// Deeper into a sound: its artists side by side on its colour, and a mix of them to play.
private struct GenreCard: View {
    let genre: String
    let artists: [SuggestedArtist]
    @Environment(PlayerModel.self) private var player
    @Environment(AppModel.self) private var model
    @State private var isStarting = false

    var body: some View {
        let color = CoverTint.color(forSeed: genre)
        VStack(alignment: .leading, spacing: 0) {
            CardWords(eyebrow: String(localized: "Deeper Into"), title: genre, line: names)
            Spacer(minLength: 0)
            HStack(spacing: -22) {
                ForEach(artists.enumerated(), id: \.element.id) { index, artist in
                    NavigationLink(value: PlayRoute.artist(artist.artist)) {
                        CoverImage(cover: artist.artist.artwork.map(CoverArt.artwork) ?? .url(nil, seed: artist.artist.name), size: Self.side, isCircle: true)
                            .overlay { Circle().strokeBorder(color, lineWidth: 4) }
                            .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                    }
                    .buttonStyle(.pressable)
                    .zIndex(Double(artists.count - index))
                    .help(artist.artist.name)
                    .accessibilityLabel(artist.artist.name)
                }
            }
            Spacer(minLength: 0)
            if model.musicSource == .appleMusic {
                CardButton(title: isStarting ? "Starting…" : "Play Them", systemImage: "play.fill", action: playThem)
                    .disabled(isStarting)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            ZStack {
                LinearGradient(colors: [color, color.mix(with: .black, by: 0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
                // The first of them, faint and large behind, so the card has their colour too.
                if let first = artists.first {
                    FillPicture(cover: first.artist.artwork.map(CoverArt.artwork) ?? .url(nil, seed: first.artist.name))
                        .blur(radius: 40)
                        .opacity(0.35)
                        .blendMode(.softLight)
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// "Ocean Tapes, Silver Lakes, and 3 more", joined as the language joins a list.
    private var names: String {
        let shown = artists.prefix(2).map(\.artist.name)
        let more = artists.count - shown.count
        guard more > 0 else { return shown.formatted(.list(type: .and)) }
        return (shown + [String(localized: "\(more) more", comment: "The last item of a list of artists, counting the ones not named")]).formatted(.list(type: .and))
    }

    /// Two of each one's best songs, shuffled together.
    private func playThem() {
        isStarting = true
        Task {
            var songs: [Song] = []
            await withTaskGroup(of: [Song].self) { group in
                for artist in artists {
                    group.addTask {
                        let top = try? await artist.artist.with([.topSongs]).topSongs
                        return top.map { Array($0.prefix(2)) } ?? []
                    }
                }
                for await found in group { songs += found }
            }
            isStarting = false
            let playable = PlayPreferences.versions(of: songs)
            guard !playable.isEmpty else {
                player.problem = .nothingToPlay
                return
            }
            player.play(.songs(playable.shuffled()), from: PlayContext(kind: .songs, title: genre))
        }
    }

    #if os(macOS)
    private static let side: CGFloat = 96
    #else
    private static let side: CGFloat = 72
    #endif
}

/// Two cards side by side, one taking about three fifths of the row and the other the rest.
/// A lone last card takes the whole row.
private struct PairedRow: Layout {
    var wideFirst: Bool
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 800, height: proposal.height ?? ArtistFeed.cardHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count > 1 else {
            subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
            return
        }
        let room = bounds.width - spacing
        let wide = (room * 0.6).rounded()
        let widths = wideFirst ? [wide, room - wide] : [room - wide, wide]
        var x = bounds.minX
        for (index, subview) in subviews.prefix(2).enumerated() {
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: widths[index], height: bounds.height))
            x += widths[index] + spacing
        }
    }
}
