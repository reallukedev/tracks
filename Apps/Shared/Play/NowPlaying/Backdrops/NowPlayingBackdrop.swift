import SwiftUI
import TracksCore

/// What fills the player behind the song, chosen in Settings.
enum NowPlayingBackground: String, CaseIterable, Identifiable {
    /// The cover's colour, deepening toward the controls.
    case colour
    /// The cover itself, blurred to fill the screen, drifting slowly while it plays.
    case artwork
    /// The cover itself, flowing, its colours swirling into one another while it plays. The default.
    case living
    /// The cover behind a pane of ribbed glass, drifting past while it plays.
    case glass
    /// Curtains of light in the cover's colours, rippling over a night sky.
    case aurora
    /// Light from behind the cover in its colours, moving with the music. Stored as "pulse",
    /// the background it took the place of, so anyone who chose that keeps one that moves.
    case halo = "pulse"

    var id: String { rawValue }

    static let storageKey = "nowPlayingBackground"
    static let defaultValue = NowPlayingBackground.living

    var title: LocalizedStringKey {
        switch self {
        case .colour: "Cover Colour"
        case .artwork: "Artwork"
        case .living: "Living Cover"
        case .glass: "Reeded Glass"
        case .aurora: "Aurora"
        case .halo: "Halo"
        }
    }

    var footer: LocalizedStringKey {
        switch self {
        case .colour: "The player takes the colour of the cover, as Music's does."
        case .artwork: "The cover fills the player, softly blurred, and drifts while the music plays."
        case .living: "The cover comes alive: its colours flow and swirl into one another while the music plays, and settle when it's paused."
        case .glass: "The cover, seen through a pane of ribbed glass, drifts slowly past while the music plays."
        case .aurora: "Curtains of light in the cover's colours ripple across a night sky while the music plays."
        case .halo: "Light spills from behind the cover in its colours and moves with the music: every beat and note of your own music, and each Apple Music song's beat and feel, learned from its preview."
        }
    }

    /// The one chosen in Settings, for a view that needs it before it's drawn.
    static var stored: NowPlayingBackground {
        UserDefaults.standard.string(forKey: storageKey).flatMap(Self.init) ?? defaultValue
    }
}

/// How the background turns into the next song's.
enum BackdropChange: String, CaseIterable, Identifiable {
    case crossfade, slide, bloom

    var id: String { rawValue }

    static let storageKey = "nowPlayingBackdropChange"

    var title: LocalizedStringKey {
        switch self {
        case .crossfade: "Crossfade"
        case .slide: "Slide"
        case .bloom: "Bloom"
        }
    }
}

/// The player's background: the chosen style, for the song on, changing to the next song's
/// the chosen way.
///
/// A new song's background waits, a second at most, for its cover to be readied, so the
/// change goes straight to it; the one leaving stays whole under the one arriving until it's
/// covered, so nothing dips to black on the way. Under Reduce Motion nothing moves, and
/// songs cross-fade. With Increase Contrast it's a little deeper, for the words on it.
struct NowPlayingBackdrop: View {
    let cover: CoverArt?
    /// The cover's colour, read by the player for its buttons: the field until the cover's
    /// readied, and for a cover with no picture at all.
    let tint: Color?
    let isPlaying: Bool
    /// A preview in Settings: this style, whatever's chosen.
    var style: NowPlayingBackground?
    /// Where the cover sits, in this view's space, for a background lit from behind it.
    var focus: CGRect?
    @AppStorage(NowPlayingBackground.storageKey) private var chosen = NowPlayingBackground.defaultValue
    @AppStorage(BackdropChange.storageKey) private var change = BackdropChange.crossfade
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var layer: Layer

    init(cover: CoverArt?, tint: Color?, isPlaying: Bool, style: NowPlayingBackground? = nil, focus: CGRect? = nil) {
        self.cover = cover
        self.tint = tint
        self.isPlaying = isPlaying
        self.style = style
        self.focus = focus
        // A cover already readied is there in the first frame, with nothing to fade from.
        _layer = State(initialValue: Layer(
            style: style ?? .stored,
            cover: cover,
            art: BackdropArtStore.shared.cached(cover),
            generation: 0
        ))
    }

    /// What's drawn: a style, for a song, with its cover once it's readied. Each new one is
    /// drawn over the last.
    private struct Layer {
        var style: NowPlayingBackground
        var cover: CoverArt?
        var art: BackdropArt?
        var generation: Int

        var key: Key { Key(style: style, cover: cover, isReady: art != nil) }

        struct Key: Hashable {
            let style: NowPlayingBackground
            let cover: CoverArt?
            let isReady: Bool
        }
    }

    var body: some View {
        ZStack {
            Color.black
            content(layer)
                .id(layer.key)
                .zIndex(Double(layer.generation))
                .transition(transition)
        }
        .overlay {
            if contrast == .increased {
                Color.black.opacity(0.2)
            }
        }
        .clipped()
        .accessibilityHidden(true)
        .task(id: cover) { await follow(cover) }
        .onChange(of: style ?? chosen) { _, style in
            show(Layer(style: style, cover: layer.cover, art: layer.art, generation: layer.generation + 1), animation: .easeInOut(duration: 0.4))
        }
    }

    @ViewBuilder
    private func content(_ layer: Layer) -> some View {
        let isMoving = isPlaying && !reduceMotion
        let field = layer.art?.field ?? tint
        switch (layer.style, layer.art) {
        case (.colour, _):
            CoverStage(tint: field)
        case (.artwork, let art?):
            ArtworkBackdrop(art: art, isMoving: isMoving)
        case (.living, let art?):
            LivingCoverBackdrop(art: art, isMoving: isMoving)
        case (.glass, let art?):
            ReededGlassBackdrop(art: art, isMoving: isMoving)
        case (.aurora, let art?):
            AuroraBackdrop(art: art, isMoving: isMoving, focus: focus)
        case (.halo, let art?):
            HaloBackdrop(art: art, isPlaying: isPlaying, focus: focus)
        case (_, nil):
            // Waiting on the cover, or a cover with no picture at all: its colour.
            CoverStage(tint: field)
        }
    }

    /// Readies the new cover and changes to it: straight away if it's ready, as soon as it
    /// is if that's within a second, and otherwise to its colour first, then to it.
    private func follow(_ cover: CoverArt?) async {
        guard let cover else { return }
        if layer.cover == cover, layer.art != nil { return }
        if let art = BackdropArtStore.shared.cached(cover) {
            show(cover, art)
            return
        }
        await withTaskGroup(of: BackdropArt??.self) { group in
            group.addTask { .some(await BackdropArtStore.shared.art(for: cover)) }
            group.addTask {
                try? await Task.sleep(for: .seconds(1))
                return .none
            }
            for await result in group {
                guard !Task.isCancelled else { return }
                if let art = result {
                    show(cover, art)
                    group.cancelAll()
                    return
                }
                show(cover, nil)
            }
        }
    }

    private func show(_ cover: CoverArt, _ art: BackdropArt?) {
        show(Layer(style: layer.style, cover: cover, art: art, generation: layer.generation + 1), animation: songAnimation)
    }

    private func show(_ next: Layer, animation: Animation) {
        guard next.key != layer.key else { return }
        withAnimation(reduceMotion ? .easeInOut(duration: Self.reducedDuration) : animation) {
            layer = next
        }
    }

    private var transition: AnyTransition {
        // The one leaving stays whole until the one arriving has covered it.
        let stays = AnyTransition.opacity.animation(.linear(duration: 0.05).delay(reduceMotion ? Self.reducedDuration : duration))
        guard !reduceMotion else { return .asymmetric(insertion: .opacity, removal: stays) }
        switch change {
        case .crossfade: return .asymmetric(insertion: .opacity, removal: stays)
        case .slide: return .asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading))
        case .bloom:
            // Opening out from the cover, as light through a doorway, rather than a picture
            // growing from a box in the middle.
            let reveal = AnyTransition.modifier(
                active: BloomReveal(progress: 0, origin: focus.map { CGPoint(x: $0.midX, y: $0.midY) }),
                identity: BloomReveal(progress: 1, origin: focus.map { CGPoint(x: $0.midX, y: $0.midY) })
            )
            return .asymmetric(insertion: reveal, removal: stays)
        }
    }

    private static let reducedDuration = 0.4

    private var duration: Double {
        switch change {
        case .crossfade: 0.8
        case .slide: 0.6
        case .bloom: 0.9
        }
    }

    private var songAnimation: Animation {
        switch change {
        case .crossfade: .easeInOut(duration: duration)
        case .slide: .smooth(duration: duration)
        case .bloom: .smooth(duration: duration)
        }
    }
}

/// A new background opening out in a widening circle from the cover, its edge soft, settling
/// from a touch larger as it does.
private struct BloomReveal: ViewModifier, Animatable {
    var progress: Double
    /// Where it opens from, in the view's space: the middle of the cover, or high and central.
    let origin: CGPoint?

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(1 + 0.06 * (1 - progress))
            .mask {
                GeometryReader { proxy in
                    let size = proxy.size
                    let centre = origin ?? CGPoint(x: size.width / 2, y: size.height * 0.35)
                    // Far enough to reach the farthest corner, with the soft edge past it.
                    let reach = hypot(max(centre.x, size.width - centre.x), max(centre.y, size.height - centre.y)) * 1.3
                    if progress < 1 {
                        RadialGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: max(0, progress - 0.22)),
                                .init(color: .clear, location: max(0.001, progress)),
                            ],
                            center: UnitPoint(x: centre.x / max(1, size.width), y: centre.y / max(1, size.height)),
                            startRadius: 0,
                            endRadius: reach
                        )
                    } else {
                        Color.black
                    }
                }
            }
    }
}

/// The player's background, lit from wherever the player marked its cover with
/// ``SwiftUI/View/backdropFocus()``.
struct FocusedBackdrop: ViewModifier {
    let cover: CoverArt?
    let tint: Color?
    let isPlaying: Bool
    var style: NowPlayingBackground?

    func body(content: Content) -> some View {
        content.backgroundPreferenceValue(BackdropFocusKey.self) { anchor in
            GeometryReader { proxy in
                NowPlayingBackdrop(cover: cover, tint: tint, isPlaying: isPlaying, style: style, focus: anchor.map { proxy[$0] })
            }
            .ignoresSafeArea()
        }
    }
}

extension View {
    /// The player's background behind this, lit from its cover.
    func nowPlayingBackdrop(cover: CoverArt?, tint: Color?, isPlaying: Bool, style: NowPlayingBackground? = nil) -> some View {
        modifier(FocusedBackdrop(cover: cover, tint: tint, isPlaying: isPlaying, style: style))
    }
}

/// Settings' choice of background: each style as a small live player to tap, as Display &
/// Brightness shows Light and Dark, and how it changes between songs. With nothing playing
/// they show a sample cover, so each can still be told apart.
struct NowPlayingBackdropPicker: View {
    @AppStorage(NowPlayingBackground.storageKey) private var chosen = NowPlayingBackground.defaultValue
    @Environment(PlayerModel.self) private var player
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let columns = dynamicTypeSize.isAccessibilitySize ? 2 : 3
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: columns),
            spacing: 18
        ) {
            ForEach(NowPlayingBackground.allCases) { style in
                tile(style)
            }
        }
        .padding(.vertical, 8)
        .sensoryFeedback(.selection, trigger: chosen)
    }

    private func tile(_ style: NowPlayingBackground) -> some View {
        let isChosen = chosen == style
        return Button {
            withAnimation(.snappy) { chosen = style }
        } label: {
            VStack(spacing: 7) {
                // Only the chosen one moves while the music plays, as the player would: six
                // moving at once is noise, and Settings left open would keep them all drawing.
                BackdropMiniature(style: style, cover: cover, isPlaying: player.isPlaying && isChosen)
                    .clipShape(.rect(cornerRadius: Self.radius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                            .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
                    }
                    // The ring sits just outside the preview, as the Appearance choices' do.
                    .padding(3)
                    .overlay {
                        RoundedRectangle(cornerRadius: Self.radius + 3, style: .continuous)
                            .strokeBorder(.tint, lineWidth: 2.5)
                            .opacity(isChosen ? 1 : 0)
                    }
                Text(style.title)
                    .font(.caption.weight(isChosen ? .semibold : .regular))
                    .foregroundStyle(isChosen ? .primary : .secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isChosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .imageScale(.medium)
                    .contentTransition(.symbolEffect(.replace))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(style.title))
        .accessibilityHint(Text(style.footer))
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    private static let radius: CGFloat = 12

    /// The song on, or a sample.
    private var cover: CoverArt { player.current?.cover ?? .url(nil, seed: Self.sample) }

    /// A stand-in cover in a few colours, so each style shows what it does with one.
    static let sample = "Tracks Sample"
}

/// A style at the size of a thumb: the player in miniature over it, a cover and its lines,
/// laid out as the player is on this device.
private struct BackdropMiniature: View {
    let style: NowPlayingBackground
    let cover: CoverArt
    let isPlaying: Bool

    var body: some View {
        GeometryReader { proxy in
            layout(in: proxy.size)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(Self.aspect, contentMode: .fit)
        .nowPlayingBackdrop(cover: cover, tint: nil, isPlaying: isPlaying, style: style)
        .environment(\.colorScheme, .dark)
    }

    #if os(macOS)
    /// The Mac's full player: the cover left, its song beside it.
    private static let aspect: CGFloat = 1.5

    private func layout(in size: CGSize) -> some View {
        let side = size.height * 0.52
        return HStack(spacing: size.width * 0.07) {
            CoverImage(cover: cover, size: side, isBare: true)
                .clipShape(.rect(cornerRadius: 3, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                .backdropFocus()
            lines(width: size.width * 0.3, alignment: .leading)
        }
    }
    #else
    /// iPhone's player: the cover high, its song under it, the scrubber by the thumb.
    private static let aspect: CGFloat = 0.6

    private func layout(in size: CGSize) -> some View {
        let side = size.width * 0.66
        return VStack(spacing: 0) {
            CoverImage(cover: cover, size: side, isBare: true)
                .clipShape(.rect(cornerRadius: 4, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                .backdropFocus()
                .padding(.top, size.height * 0.14)
            lines(width: side, alignment: .leading)
                .padding(.top, size.height * 0.07)
            Spacer(minLength: 0)
            Capsule().fill(.white.opacity(0.3)).frame(width: side, height: 2)
                .padding(.bottom, size.height * 0.1)
        }
    }
    #endif

    private func lines(width: CGFloat, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            Capsule().fill(.white.opacity(0.85)).frame(width: width * 0.7, height: 3)
            Capsule().fill(.white.opacity(0.45)).frame(width: width * 0.45, height: 3)
        }
        .frame(width: width, alignment: Alignment(horizontal: alignment, vertical: .center))
    }
}

/// Settings ▸ Play ▸ Now Playing: the background, whether Living Cover moves with the music,
/// how the background changes between songs, and whether the player shows the quality you're
/// hearing.
struct NowPlayingBackdropSection: View {
    @AppStorage(NowPlayingBackground.storageKey) private var chosen = NowPlayingBackground.defaultValue
    @AppStorage(LivingCoverOption.movesWithMusic) private var movesWithMusic = true
    @AppStorage(BackdropChange.storageKey) private var change = BackdropChange.crossfade
    @AppStorage(AudioQualityBadge.showsKey) private var showsQuality = true

    var body: some View {
        Section {
            NowPlayingBackdropPicker()
            if chosen == .living {
                SettingsSwitch(
                    "Move with the Music",
                    detail: Text(PlaySettingsWords.livingCoverDetail(movesWithMusic: movesWithMusic)),
                    isOn: $movesWithMusic
                )
            }
            Picker("Between Songs", selection: $change) {
                ForEach(BackdropChange.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            SettingsSwitch(
                "Show Audio Quality",
                detail: Text(PlaySettingsWords.audioQualityDetail(isShown: showsQuality)),
                isOn: $showsQuality
            )
        } header: {
            Text("Now Playing")
        } footer: {
            #if os(macOS)
            Text(chosen.footer)
                .contentTransition(.opacity)
            #else
            // The iPhone's switches have no detail line: their sentences follow the background's.
            let quality = PlaySettingsWords.audioQualityDetail(isShown: showsQuality)
            Group {
                if chosen == .living {
                    Text("\(PlaySettingsWords.livingCoverFooter(movesWithMusic: movesWithMusic)) \(quality)")
                } else {
                    Text("\(Text(chosen.footer)) \(quality)")
                }
            }
            .contentTransition(.opacity)
            #endif
        }
    }
}
