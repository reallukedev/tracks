import SwiftUI
import TracksCore

/// The shape every artist's page shares, whichever music they're in: their picture, their
/// name, what Tracks knows of you and them ("Your No. 3 artist · 412 plays since 2023"), then
/// the page's own sections, About them, and your own top songs by them last: the page is
/// about the artist first and your history with them second.
///
/// On iPhone the picture fills the top edge to edge under the navigation bar, with the name
/// over its foot and a round Play button, as Music's artist page is. On the Mac it's a band of
/// the picture's colour with the picture in a circle, and Play, Station and Shuffle beside it.
struct ArtistScaffold<Sections: View, More: View>: View {
    let name: String
    /// Their picture, or nil for a monogram.
    let picture: CoverArt?
    var play: (() -> Void)?
    var shuffle: (() -> Void)?
    /// Apple Music's station for them, where there is one.
    var station: (() -> Void)?
    /// Your own top songs by them, from the history, after the page's sections. Off where the
    /// page's own songs already are yours.
    var showsYourTopSongs = true
    /// What's known about them beyond your listening, for the About section.
    var about: ArtistAbout?
    @ViewBuilder var more: More
    @ViewBuilder var sections: Sections

    @Environment(AppModel.self) private var model
    @Environment(\.openPlayRoute) private var openPlayRoute
    @State private var story: ArtistStoryState = .reading
    #if os(iOS)
    @State private var showsTitle = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #else
    /// The picture's colour, for the band behind it.
    @State private var tint: Color?
    #endif

    private var identity: String { StatsCalculator.folded(name) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                VStack(alignment: .leading, spacing: PlayMetrics.sectionSpacing) {
                    #if os(iOS)
                    YourListeningRow(identity: identity, story: story)
                    #endif
                    sections
                    if let about {
                        AboutArtistSection(name: name, about: about, firstHeard: story.story?.firstHeard)
                            .transition(.opacity)
                    }
                    if showsYourTopSongs, case .found(let found) = story, !found.topSongs.isEmpty {
                        ArtistYourTopSongs(artist: name, songs: found.topSongs)
                    }
                }
                .padding(.top, topSpacing)
                .padding(.bottom, PlayMetrics.sectionSpacing)
            }
        }
        .launchScroll()
        #if os(iOS)
        .ignoresSafeArea(.container, edges: .top)
        // The picture meets the top edge clean; the bar's edge comes back once it's scrolled by.
        .scrollEdgeEffectHidden(!showsTitle, for: .top)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y > geometry.containerSize.width * headerRatio - 90
        } action: { _, past in
            showsTitle = past
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(name)
                    .font(.headline)
                    .lineLimit(1)
                    .opacity(showsTitle ? 1 : 0)
                    // The name is read once, in the picture, until this one shows.
                    .accessibilityHidden(!showsTitle)
                    .animation(PlayMotion.value, value: showsTitle)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu("More", systemImage: "ellipsis") {
                    actionItems
                    more
                    Divider()
                    BlockArtistButton(artist: name)
                }
            }
        }
        .toolbarTitleDisplayMode(.inline)
        #else
        .toolbar(removing: .title)
        .coverTint(of: picture, into: $tint)
        #endif
        .navigationTitle(name)
        .task(id: model.library.revision) {
            let (identity, history) = (identity, model.library.history)
            let found = await OffMainActor.run { ArtistStories.story(of: identity, in: history) }
            story = found.map(ArtistStoryState.found) ?? .none
        }
    }

    // MARK: Header

    #if os(iOS)
    /// The picture's height against the width: square, or shorter for a monogram.
    private var headerRatio: CGFloat { picture == nil ? 0.9 : 1 }

    private var topSpacing: CGFloat { 16 }

    private var header: some View {
        Color.clear
            .aspectRatio(1 / headerRatio, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    Group {
                        if let picture {
                            CoverImage(cover: picture, size: proxy.size.width, isBare: true)
                                .frame(width: proxy.size.width, height: proxy.size.height)
                        } else {
                            ZStack {
                                CoverStage(tint: nil, deepens: false)
                                // Between the navigation bar and the name; at the largest text
                                // sizes the name needs the room.
                                if !dynamicTypeSize.isAccessibilitySize {
                                    ArtistMonogram(name: name, size: 120, onStage: true)
                                        .offset(y: 14)
                                }
                            }
                        }
                    }
                    // Pulled down past the top, the picture grows to keep filling it.
                    .visualEffect { content, geometry in
                        let pull = max(0, geometry.frame(in: .scrollView).minY)
                        return content.scaleEffect(1 + pull / max(1, geometry.size.height), anchor: .bottom)
                    }
                }
            }
            .overlay {
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                HStack(alignment: .bottom, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        BlockedArtistTag(name: name)
                        Text(name)
                            .font(.largeTitle.bold())
                            .foregroundStyle(.white)
                            .lineLimit(3)
                            .minimumScaleFactor(0.6)
                            .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
                            .accessibilityAddTraits(.isHeader)
                    }
                    Spacer(minLength: 0)
                    if let play {
                        ArtistPlayCircle(action: play)
                    }
                }
                .padding(.horizontal, PlayMetrics.margin)
                .padding(.bottom, 20)
                // The name over the picture stops growing where it would cover it.
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            }
            .clipped()
    }
    #else
    private var topSpacing: CGFloat { PlayMetrics.sectionSpacing - 8 }

    private var header: some View {
        HStack(spacing: 32) {
            ArtistPicture(cover: picture, name: name, size: 200, onStage: true)
                .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
            VStack(alignment: .leading, spacing: 6) {
                Text(name)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                ArtistSignatureLink(identity: identity, story: story)
                BlockedArtistTag(name: name)
                    .padding(.top, 6)
                HStack(spacing: 10) {
                    if let play {
                        Button("Play", systemImage: "play.fill", action: play)
                            .buttonStyle(.stagePrimary(tint: tint))
                    }
                    if let station {
                        Button("Station", systemImage: "dot.radiowaves.left.and.right", action: station)
                            .buttonStyle(.stageSecondary)
                    }
                    if let shuffle {
                        Button("Shuffle", systemImage: "shuffle", action: shuffle)
                            .buttonStyle(.stageSecondary)
                    }
                    Menu {
                        more
                        Divider()
                        Button("Your Stats", systemImage: "chart.bar.xaxis") {
                            openPlayRoute(.stats(.artist(identity)))
                        }
                        Divider()
                        BlockArtistButton(artist: name)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: StageButtonStyle.height, height: StageButtonStyle.height)
                            .background(.white.opacity(0.2), in: .circle)
                            .contentShape(.circle)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More")
                    .accessibilityLabel("More")
                }
                .padding(.top, 12)
            }
            .environment(\.colorScheme, .dark)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PlayMetrics.margin + 12)
        .frame(height: 280)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Up under the toolbar too, as Music's artist pages are.
        .background { CoverStage(tint: picture == nil ? nil : tint, deepens: false).ignoresSafeArea(edges: .top) }
    }
    #endif

    /// Play's companions, for the iPhone's More menu; the Mac has them as buttons.
    @ViewBuilder
    private var actionItems: some View {
        if let shuffle {
            Button("Shuffle", systemImage: "shuffle", action: shuffle)
        }
        if let station {
            Button("Create Station", systemImage: "dot.radiowaves.left.and.right", action: station)
        }
        Button("Your Stats", systemImage: "chart.bar.xaxis") {
            openPlayRoute(.stats(.artist(identity)))
        }
        Divider()
    }
}

extension ArtistScaffold where More == EmptyView {
    init(
        name: String,
        picture: CoverArt?,
        play: (() -> Void)? = nil,
        shuffle: (() -> Void)? = nil,
        station: (() -> Void)? = nil,
        showsYourTopSongs: Bool = true,
        about: ArtistAbout? = nil,
        @ViewBuilder sections: () -> Sections
    ) {
        self.name = name
        self.picture = picture
        self.play = play
        self.shuffle = shuffle
        self.station = station
        self.showsYourTopSongs = showsYourTopSongs
        self.about = about
        self.more = EmptyView()
        self.sections = sections()
    }
}

/// What the history has on an artist, while it's still being read and once it has been.
enum ArtistStoryState: Equatable {
    case reading
    case none
    case found(ArtistStory)

    var story: ArtistStory? {
        if case .found(let story) = self { story } else { nil }
    }
}

/// The line under an artist's name: "Your No. 3 artist · 412 plays since 2023".
enum ArtistSignature {
    static func line(_ story: ArtistStory, now: Date = .now, calendar: Calendar = .current) -> String {
        let plays = PlayCountText.short(story.plays)
        let since = calendar.isDate(story.firstHeard, equalTo: now, toGranularity: .year)
            ? story.firstHeard.formatted(.dateTime.month(.wide))
            : story.firstHeard.formatted(.dateTime.year())
        let count = String(localized: "\(plays) since \(since)")
        guard let rank = story.rank else { return count }
        return String(localized: "Your No. \(rank) artist · \(count)")
    }
}

#if os(iOS)
/// Under the picture on iPhone: the signature line, opening your stats for the artist.
private struct YourListeningRow: View {
    let identity: String
    let story: ArtistStoryState

    var body: some View {
        switch story {
        case .reading:
            // The row's shape, so the page doesn't jump when the history's been read.
            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(Color.placeholderFill).frame(width: 120, height: 12)
                Capsule().fill(Color.placeholderFill).frame(width: 220, height: 10)
            }
            .frame(minHeight: 44, alignment: .leading)
            .padding(.horizontal, PlayMetrics.margin)
            .accessibilityHidden(true)
        case .none:
            EmptyView()
        case .found(let found):
            NavigationLink(value: Route.artist(identity)) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your Listening")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(ArtistSignature.line(found))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.forward")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.pressable)
            .padding(.horizontal, PlayMetrics.margin)
        }
    }
}

/// Music's round Play on an artist's picture: the accent, 56 points.
private struct ArtistPlayCircle: View {
    let action: () -> Void
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            Image(systemName: "play.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Color.accentColor, in: .circle)
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        }
        .buttonStyle(.pressable)
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
        .accessibilityLabel("Play")
    }
}
#else
/// Under the name on the Mac: the signature line, opening your stats for the artist.
private struct ArtistSignatureLink: View {
    let identity: String
    let story: ArtistStoryState
    @Environment(\.openPlayRoute) private var openPlayRoute
    @State private var isHovered = false

    var body: some View {
        switch story {
        case .reading:
            Capsule().fill(.white.opacity(0.14)).frame(width: 240, height: 11)
                .frame(height: 17)
                .accessibilityHidden(true)
        case .none:
            Text("New to you")
                .font(.body)
                .foregroundStyle(.secondary)
        case .found(let found):
            Button {
                openPlayRoute(.stats(.artist(identity)))
            } label: {
                HStack(spacing: 4) {
                    Text(ArtistSignature.line(found))
                        .monospacedDigit()
                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .opacity(isHovered ? 1 : 0.6)
                }
                .font(.body)
                .foregroundStyle(isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { hovering in withAnimation(PlayMotion.hover) { isHovered = hovering } }
            .help("Your Listening")
        }
    }
}
#endif

/// An artist's picture in a circle, or their initials where there's none, as Contacts draws
/// someone without a photo.
struct ArtistPicture: View {
    let cover: CoverArt?
    let name: String
    let size: CGFloat
    /// On a field of colour, where the monogram is a veil of white rather than grey.
    var onStage = false

    var body: some View {
        if let cover {
            CoverImage(cover: cover, size: size, isCircle: true)
        } else {
            ArtistMonogram(name: name, size: size, onStage: onStage)
        }
    }
}

/// An artist's initials in a circle.
struct ArtistMonogram: View {
    let name: String
    let size: CGFloat
    var onStage = false

    var body: some View {
        Text(Self.initials(of: name))
            .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background {
                if onStage {
                    Circle().fill(.white.opacity(0.16))
                } else {
                    // The hue a generated cover would have for the name, so a list of artists
                    // without pictures still tells them apart at a glance.
                    let hue = CoverTint.color(forSeed: name)
                    Circle().fill(LinearGradient(colors: [hue.mix(with: .white, by: 0.45), hue.mix(with: .white, by: 0.2)], startPoint: .top, endPoint: .bottom))
                }
            }
            .accessibilityHidden(true)
    }

    /// The first letters of the first two words: "MS" for Mara Solis, "T" for The, and a
    /// music note where the name has no letters.
    static func initials(of name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).filter { $0.first?.isLetter == true }
        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "♪" : letters.joined()
    }
}

/// A picture for an artist from a web address, or nil when there isn't one.
extension CoverArt {
    static func artistPicture(url: String?, name: String) -> CoverArt? {
        guard let url, !url.isEmpty else { return nil }
        return .url(url, seed: name)
    }
}

/// Over a blocked artist's name on their page: why nothing of theirs plays or comes up.
/// Unblocked from the page's More menu, or Blocked Artists in Settings.
struct BlockedArtistTag: View {
    let name: String
    @Environment(PlayerModel.self) private var player

    var body: some View {
        if player.isBlocked(artist: name) {
            Label("Blocked", systemImage: "nosign")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.black.opacity(0.35), in: .capsule)
                .accessibilityLabel("Blocked. Tracks won't play or suggest this artist.")
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }
}
