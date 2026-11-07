import SwiftUI
import MusicKit
import TracksCore

extension SongLens {
    /// Each lens's colour, for its chip and the deck's glow before a cover's is read.
    var color: Color {
        switch self {
        case .forYou: .accentColor
        case .yourArtists: .blue
        case .likeYourArtists: .teal
        case .newReleases: .orange
        case .popular: .pink
        case .mood(let mood): mood.color
        }
    }
}

/// The lenses, as coloured chips to scroll through: each its own colour, the chosen one full.
struct LensChips: View {
    @Binding var selection: SongLens
    @ScaledMetric(relativeTo: .subheadline) private var chipHeight: CGFloat = 34
    @State private var chosen = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(SongLens.all) { lens in
                        chip(lens)
                            .id(lens.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .contentMargins(.horizontal, PlayMetrics.margin, for: .scrollContent)
            .scrollIndicators(.hidden)
            .sensoryFeedback(.selection, trigger: chosen)
            .onAppear { proxy.scrollTo(selection.id, anchor: .center) }
            .onChange(of: selection) { _, lens in
                withAnimation(PlayMotion.panel) { proxy.scrollTo(lens.id, anchor: .center) }
            }
        }
    }

    private func chip(_ lens: SongLens) -> some View {
        let isSelected = lens == selection
        return Button {
            guard !isSelected else { return }
            chosen += 1
            withAnimation(PlayMotion.panel) { selection = lens }
        } label: {
            Label {
                Text(lens.title)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            } icon: {
                Image(systemName: lens.symbol)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(lens.color))
            }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .frame(minHeight: chipHeight)
                .background(isSelected ? AnyShapeStyle(lens.color) : AnyShapeStyle(lens.color.opacity(0.18)), in: .capsule)
                // A finger's worth to tap, however slim the chip draws.
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Finding songs one at a time, as you'd flip through a pile of records at a shop: the song
/// on top, large, on its cover's colour, with the next few waiting behind it. Play it, keep
/// it, or pass on to the next, with a click, the arrow keys, or a flick of the card. What you
/// keep gathers in Your Picks, to play together or add to your library.
struct SongDeck: View {
    let suggestions: [Suggestion]
    let lens: SongLens
    /// Plays the lens from this song on.
    let play: (Suggestion) -> Void
    let dismiss: ([Suggestion]) -> Void
    /// Close to the end of the pile: time to find more.
    let onNearEnd: () -> Void

    @Environment(PlayerModel.self) private var player
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title) private var titleSize: CGFloat = SongDeck.baseTitleSize
    @State private var position = 0
    @State private var picks: [Suggestion] = []
    @State private var glow: Color?
    @State private var drag: CGSize = .zero
    /// How the top card last left, so it leaves that way.
    @State private var exit = Exit.pass
    @FocusState private var isFocused: Bool

    private enum Exit { case pass, keep, back }

    private var current: Suggestion? {
        suggestions.indices.contains(position) ? suggestions[position] : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PlayMetrics.sectionSpacing) {
            stage
            if !picks.isEmpty {
                PicksTray(picks: $picks, lens: lens)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            comingUp
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: picks.map(\.id))
        .onChange(of: suggestions.map(\.id)) { _, ids in
            // The song on top was taken out: the next one takes its place.
            if position >= ids.count { position = max(0, ids.count - 1) }
        }
        .onChange(of: lens) {
            position = 0
        }
        .task(id: current?.id) {
            if position >= suggestions.count - 6 { onNearEnd() }
            guard let current else { return }
            let cover = current.song.artwork.map(CoverArt.artwork) ?? .url(nil, seed: current.song.albumTitle ?? current.song.title)
            guard let color = await CoverTint.glow(for: cover), !Task.isCancelled else { return }
            withAnimation(PlayMotion.tint) { glow = color }
        }
    }

    // MARK: - Moving through the pile

    private func pass() {
        guard position < suggestions.count - 1 else { return }
        move(.pass) { position += 1 }
    }

    private func back() {
        guard position > 0 else { return }
        move(.back) { position -= 1 }
    }

    private func keep() {
        guard let current else { return }
        if !picks.contains(current) { picks.append(current) }
        if position < suggestions.count - 1 {
            move(.keep) { position += 1 }
        }
    }

    private func move(_ how: Exit, _ change: () -> Void) {
        exit = how
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.42, bounce: 0.18)) {
            drag = .zero
            change()
        }
    }

    // MARK: - Stage

    private var stage: some View {
        let layout = Self.isWide
            ? AnyLayout(HStackLayout(alignment: .center, spacing: 48))
            : AnyLayout(VStackLayout(alignment: .center, spacing: 24))
        return layout {
            pile
                .frame(width: Self.side + 70, height: Self.side + 40)
            if let current {
                details(current)
                    .id(current.id)
                    .transition(.opacity)
                    .frame(maxWidth: Self.isWide ? 420 : .infinity, alignment: Self.isWide ? .leading : .center)
            }
        }
        .padding(.vertical, Self.isWide ? 28 : 20)
        .padding(.horizontal, Self.isWide ? 28 : 16)
        .frame(maxWidth: .infinity)
        .background {
            ZStack {
                Color.cardFill
                RadialGradient(
                    colors: [(glow ?? lens.color).opacity(0.55), (glow ?? lens.color).opacity(0.08)],
                    center: .init(x: Self.isWide ? 0.3 : 0.5, y: 0.35),
                    startRadius: 20,
                    endRadius: 520
                )
            }
            .animation(PlayMotion.tint, value: glow)
        }
        .clipShape(.rect(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, PlayMetrics.margin)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.rightArrow) { pass(); return .handled }
        .onKeyPress(.leftArrow) { back(); return .handled }
        .onKeyPress(.upArrow) { keep(); return .handled }
        .onKeyPress(.return) {
            if let current { play(current) }
            return .handled
        }
        #if os(macOS)
        .onDeleteCommand {
            if let current { dismiss([current]) }
        }
        #endif
        .onAppear { isFocused = true }
    }

    /// The song on top and the two after it, fanned behind.
    private var pile: some View {
        ZStack {
            ForEach(visible.enumerated().reversed(), id: \.element.id) { depth, suggestion in
                let isTop = depth == 0
                CoverImage(cover: suggestion.song.artwork.map(CoverArt.artwork) ?? .url(nil, seed: suggestion.song.albumTitle ?? suggestion.song.title), size: Self.side)
                    .shadow(color: .black.opacity(isTop ? 0.4 : 0.2), radius: isTop ? 24 : 12, y: isTop ? 14 : 6)
                    .scaleEffect(1 - 0.07 * CGFloat(depth))
                    .rotationEffect(.degrees(isTop ? Double(drag.width) / 22 : Double(depth) * 4))
                    .offset(x: (isTop ? drag.width : CGFloat(depth) * 26), y: isTop ? drag.height * 0.3 : CGFloat(depth) * -10)
                    .brightness(isTop ? 0 : -0.08 * Double(depth))
                    .zIndex(Double(10 - depth))
                    .transition(.asymmetric(insertion: .opacity, removal: removal))
                    .gesture(flick, isEnabled: isTop)
                    .onTapGesture {
                        if isTop { play(suggestion) }
                    }
                    .accessibilityHidden(!isTop)
                    .accessibilityLabel(Text("\(suggestion.song.title), \(suggestion.song.artistName)"))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Plays this song.")
            }
        }
        .offset(x: -18)
    }

    private var visible: [Suggestion] {
        Array(suggestions.dropFirst(position).prefix(3))
    }

    /// The way the top card leaves: off to the left when passed, up into Your Picks when kept.
    private var removal: AnyTransition {
        guard !reduceMotion else { return .opacity }
        switch exit {
        case .pass: return .offset(x: -Self.side * 1.4, y: 30).combined(with: .opacity)
        case .keep: return .offset(y: -Self.side).combined(with: .scale(scale: 0.4)).combined(with: .opacity)
        case .back: return .opacity
        }
    }

    /// A flick of the top card: left to pass, right to keep.
    private var flick: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in drag = value.translation }
            .onEnded { value in
                if value.translation.width < -110 || value.predictedEndTranslation.width < -260 {
                    pass()
                } else if value.translation.width > 110 || value.predictedEndTranslation.width > 260 {
                    keep()
                } else {
                    withAnimation(.spring(duration: 0.35, bounce: 0.3)) { drag = .zero }
                }
            }
    }

    private func details(_ suggestion: Suggestion) -> some View {
        let song = suggestion.song
        let alignment: HorizontalAlignment = Self.isWide ? .leading : .center
        return VStack(alignment: alignment, spacing: 6) {
            Label(suggestion.reason.line, systemImage: suggestion.reason.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(song.title)
                .font(.system(size: titleSize, weight: .bold))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            Text(song.artistName)
                .font(.title3.weight(.medium))
                .foregroundStyle(.tint)
                .lineLimit(1)
            Text([song.albumTitle, song.genreNames.first(where: { $0 != "Music" }), song.releaseDate.map { $0.formatted(.dateTime.year()) }].compactMap(\.self).joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(spacing: 18) {
                roundButton("Pass", systemImage: "xmark", size: 52, prominent: false, action: pass)
                    .help("Pass (→)")
                    .disabled(position >= suggestions.count - 1)
                roundButton("Play", systemImage: "play.fill", size: 68, prominent: true) { play(suggestion) }
                    .help("Play (Return)")
                roundButton(picks.contains(suggestion) ? "Kept" : "Keep", systemImage: picks.contains(suggestion) ? "heart.fill" : "heart", size: 52, prominent: false, action: keep)
                    .help("Keep in Your Picks (↑)")
                Menu {
                    SuggestionMenu(suggestion: suggestion) { dismiss([suggestion]) }
                } label: {
                    Label("More", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                }
                .menuIndicator(.hidden)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .fixedSize()
            }
            .padding(.top, 18)

            HStack(spacing: 12) {
                if position > 0 {
                    Button("Back", systemImage: "arrow.uturn.backward", action: back)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                Text("\(position + 1) of \(suggestions.count)")
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .font(.caption)
            .padding(.top, 10)
        }
        .multilineTextAlignment(Self.isWide ? .leading : .center)
    }

    private func roundButton(_ title: LocalizedStringKey, systemImage: String, size: CGFloat, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.36, weight: .bold))
                .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .frame(width: size, height: size)
                .background(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.regularMaterial), in: .circle)
                .contentShape(.circle)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(Text(title))
    }

    // MARK: - Coming up

    /// What's under the pile, to skip ahead to.
    @ViewBuilder
    private var comingUp: some View {
        let next = Array(suggestions.dropFirst(position + 1).prefix(20))
        if !next.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Coming Up")
                    .font(.title3.bold())
                    .padding(.horizontal, PlayMetrics.margin)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(next.enumerated(), id: \.element.id) { offset, suggestion in
                            Button {
                                move(.pass) { position += offset + 1 }
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    CoverImage(cover: suggestion.song.artwork.map(CoverArt.artwork) ?? .url(nil, seed: suggestion.song.albumTitle ?? suggestion.song.title), size: 112)
                                    Text(suggestion.song.title)
                                        .font(.caption.weight(.medium))
                                        .lineLimit(1)
                                    Text(suggestion.song.artistName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(width: 112, alignment: .leading)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.pressable)
                            .contextMenu { SuggestionMenu(suggestion: suggestion) { dismiss([suggestion]) } }
                        }
                    }
                }
                .contentMargins(.horizontal, PlayMetrics.margin, for: .scrollContent)
                .scrollIndicators(.hidden)
            }
        }
    }

    #if os(macOS)
    private static let side: CGFloat = 300
    private static let baseTitleSize: CGFloat = 34
    private static let isWide = true
    #else
    private static let side: CGFloat = 200
    private static let baseTitleSize: CGFloat = 26
    private static let isWide = false
    #endif
}

/// What you've kept from the pile: to play together, or to add to your library all at once.
private struct PicksTray: View {
    @Binding var picks: [Suggestion]
    let lens: SongLens
    @Environment(PlayerModel.self) private var player
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Your Picks")
                        .font(.title3.bold())
                    Text(String(AttributedString(localized: "^[\(picks.count) song](inflect: true) kept").characters))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    player.play(.songs(picks.map(\.song)), from: .songs(String(localized: "Your Picks")))
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(.glassProminent)
                if !player.isDemo, model.musicSource == .appleMusic {
                    Button {
                        for pick in picks { player.addToLibrary(pick.song) }
                    } label: {
                        Label("Add All", systemImage: "plus")
                    }
                    .buttonStyle(.glass)
                }
                Button("Clear", role: .destructive) { picks = [] }
                    .buttonStyle(.glass)
            }
            .buttonBorderShape(.capsule)

            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(picks) { pick in
                        CoverImage(cover: pick.song.artwork.map(CoverArt.artwork) ?? .url(nil, seed: pick.song.albumTitle ?? pick.song.title), size: 56)
                            .help("\(pick.song.title), \(pick.song.artistName)")
                            .contextMenu {
                                Button("Remove from Your Picks", systemImage: "minus.circle") {
                                    picks.removeAll { $0.id == pick.id }
                                }
                            }
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(18)
        .background(Color.cardFill, in: .rect(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, PlayMetrics.margin)
    }
}
