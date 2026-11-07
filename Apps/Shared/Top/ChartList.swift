import SwiftUI
import TracksCore

/// The chart itself: every entry in order, with its place, its cover, how it moved, and its
/// plays. A song's place turns into a play button under the pointer, as a track number does
/// in Music; a click anywhere else opens the entry. On the Mac the arrow keys move a selection
/// through it, Return plays the selected song (or opens anything else), and ⌘↓ opens it.
struct ChartList: View {
    let entries: [ChartEntry]
    let open: (ChartEntry) -> Void
    /// The selected entry, which is the one with the keyboard's focus.
    @FocusState private var selection: ChartEntry.ID?
    private var playback = ChartPlayback()

    init(entries: [ChartEntry], open: @escaping (ChartEntry) -> Void) {
        self.entries = entries
        self.open = open
    }

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(entries.enumerated(), id: \.element.id) { index, entry in
                row(entry, index: index)
            }
        }
    }

    private func row(_ entry: ChartEntry, index: Int) -> some View {
        ChartListRow(position: index + 1, entry: entry, isLast: index == entries.count - 1, isSelected: selection == entry.id) {
            selection = entry.id
            open(entry)
        }
        .macDraggable(SongDrag(entry.song.map { [HistorySong($0)] } ?? []), if: entry.song != nil)
        #if os(macOS)
        .focusable()
        .focused($selection, equals: entry.id)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow, .return]) { press in
            switch press.key {
            case .upArrow, .downArrow:
                let next = index + (press.key == .upArrow ? -1 : 1)
                if entries.indices.contains(next) { selection = entries[next].id }
                // ⌘↓ opens, as in Finder.
                if press.key == .downArrow, press.modifiers.contains(.command) { open(entry) }
            default:
                if let song = entry.song, !playback.playable([song]).isEmpty {
                    playback.play([song], title: song.title)
                } else {
                    open(entry)
                }
            }
            return .handled
        }
        .onKeyPress(.escape) {
            selection = nil
            return .handled
        }
        #endif
    }
}

private struct ChartListRow: View {
    let position: Int
    let entry: ChartEntry
    let isLast: Bool
    var isSelected = false
    let open: () -> Void

    @State private var isHovered = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var cover: CGFloat = Self.coverSide
    @ScaledMetric(relativeTo: .title3) private var placeWidth: CGFloat = Self.placeSide
    private var playback = ChartPlayback()

    init(position: Int, entry: ChartEntry, isLast: Bool, isSelected: Bool, open: @escaping () -> Void) {
        self.position = position
        self.entry = entry
        self.isLast = isLast
        self.isSelected = isSelected
        self.open = open
    }

    #if os(macOS)
    private static let coverSide: CGFloat = 44
    private static let placeSide: CGFloat = 34
    #else
    private static let coverSide: CGFloat = 52
    /// Room for a NEW badge under the place.
    private static let placeSide: CGFloat = 40
    #endif

    private var playableSong: MixSong? {
        entry.song.flatMap { playback.playable([$0]).isEmpty ? nil : $0 }
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 14) {
                #if os(iOS)
                // On a phone the movement sits under the place, as in a printed chart, so
                // the title keeps the width.
                VStack(spacing: 3) {
                    place
                    if !typeSize.isAccessibilitySize {
                        ChartMovementBadge(movement: entry.movement, isCompact: true)
                    }
                }
                .frame(width: placeWidth)
                #else
                place
                    .frame(width: placeWidth)
                #endif
                ArtworkView(url: entry.artworkURL, seed: entry.artworkSeed, size: cover, isCircle: entry.isArtist)
                    .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                    .overlay { playOverCover }
                names
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !typeSize.isAccessibilitySize {
                    #if os(macOS)
                    ChartMovementBadge(movement: entry.movement)
                    #endif
                    Text(PlayCountText.short(entry.count))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                        #if os(macOS)
                        .frame(minWidth: 64, alignment: .trailing)
                        #endif
                        .contentTransition(.numericText(value: Double(entry.count)))
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(.primary.opacity(0.13)) : AnyShapeStyle(.quaternary.opacity(isHovered ? 0.6 : 0)))
            }
            .overlay(alignment: .bottom) {
                if !isLast {
                    Divider()
                        .padding(.leading, 10 + placeWidth + 14 + cover + 14)
                        .opacity(isHovered || isSelected ? 0 : 1)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(PlayMotion.hover) { isHovered = hovering }
        }
        .contextMenu { ChartEntryMenu(entry: entry, openStats: open) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens your stats")
        .accessibilityActions {
            if let song = playableSong {
                Button("Play") { playback.play([song], title: song.title) }
            }
        }
    }

    /// As in Music: under the pointer, Play sits over a song's cover.
    @ViewBuilder
    private var playOverCover: some View {
        if isHovered, let song = playableSong {
            Button {
                playback.play([song], title: song.title)
            } label: {
                Label("Play \(entry.title)", systemImage: "play.fill")
                    .labelStyle(.iconOnly)
                    .font(.callout.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: cover, height: cover)
                    // Rounded as the chart's covers are (see ArtworkView).
                    .background(.black.opacity(0.4), in: .rect(cornerRadius: max(4, cover * 0.12), style: .continuous))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Play \(entry.title)")
            .transition(.opacity)
        }
    }

    private var place: some View {
        Text(position.formatted())
            .font(.system(.title3, design: .rounded).weight(.semibold))
            .foregroundStyle(position <= 3 ? .primary : .secondary)
            .monospacedDigit()
            .minimumScaleFactor(0.6)
            .lineLimit(1)
    }

    private var names: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.title)
                .font(.body.weight(.medium))
                .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
            if let line = entry.detail ?? subtitle {
                CreditedText(text: line, credits: entry.detail == nil ? entry.credits : [], linkStyle: .row)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if typeSize.isAccessibilitySize {
                Text(PlayCountText.short(entry.count))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// A song's artist and album, an album's artist.
    private var subtitle: String? {
        switch (entry.subtitle, entry.album) {
        case (let artist?, let album?) where !album.isEmpty: "\(artist) · \(album)"
        case (let artist?, _): artist
        default: nil
        }
    }

    private var accessibilityLabel: Text {
        Text("Number \(position), \(entry.title), \(subtitle ?? ""), \(PlayCountText.short(entry.count))")
    }
}

/// How an entry moved since the period before: up or down in places, or new. Nothing when it
/// stayed put, or there's no period before to compare with.
struct ChartMovementBadge: View {
    let movement: ChartMovement
    /// Under a place: no room held for it when there's nothing to say.
    var isCompact = false

    var body: some View {
        Group {
            switch movement {
            case .new:
                Text("New")
                    .font(.caption2.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.tint.opacity(0.14), in: .capsule)
                    .accessibilityLabel("New entry")
            case .up(let places):
                Label("\(places)", systemImage: "arrow.up")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Up \(places)")
            case .down(let places):
                Label("\(places)", systemImage: "arrow.down")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Down \(places)")
            case .same, .none:
                EmptyView()
            }
        }
        .labelStyle(MovementLabelStyle())
        .lineLimit(1)
        .fixedSize()
        .frame(minWidth: isCompact ? nil : 40, alignment: isCompact ? .center : .trailing)
    }
}

private struct MovementLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon
                .font(.caption2.weight(.bold))
            configuration.title
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
    }
}
