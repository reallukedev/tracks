import SwiftUI
import TracksCore

/// A section of a room's page: its title, a line on what's in it where that needs saying, and
/// an action at the trailing edge.
struct RoomSectionHeader<Trailing: View>: View {
    let title: String
    var note: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ShelfHeader(title: title) { trailing }
            if let note {
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 4)
    }
}

extension RoomSectionHeader where Trailing == EmptyView {
    init(title: String, note: String? = nil) {
        self.init(title: title, note: note) { EmptyView() }
    }
}

/// Rows, a column on iPhone; on the Mac as many columns as the window has room for, read down
/// each column as Music's song grids are, so a big window shows more rather than wider rows.
struct RoomColumns<Item: Identifiable, Row: View>: View {
    let items: [Item]
    /// Where the rule under a row starts: at its words.
    var ruleInset = RoomSongRow.textInset
    @ViewBuilder var row: (Item) -> Row

    var body: some View {
        #if os(macOS)
        ViewThatFits(in: .horizontal) {
            columns(5)
            columns(4)
            columns(3)
            columns(2)
            columns(1)
        }
        #else
        column(items)
        #endif
    }

    #if os(macOS)
    private func columns(_ count: Int) -> some View {
        // Spread evenly, the first columns a row longer where it doesn't divide.
        let used = min(count, items.count)
        let chunks: [[Item]] = (0..<used).map { column in
            let start = column * (items.count / used) + min(column, items.count % used)
            let length = items.count / used + (column < items.count % used ? 1 : 0)
            return Array(items[start..<start + length])
        }
        return HStack(alignment: .top, spacing: 32) {
            ForEach(chunks.indices, id: \.self) { index in
                column(chunks[index])
                    .frame(minWidth: Self.columnWidth, idealWidth: Self.columnWidth, maxWidth: .infinity, alignment: .top)
            }
            // A short list in a wide window keeps its columns' width rather than spreading.
            ForEach(chunks.count..<count, id: \.self) { _ in
                Color.clear
                    .frame(minWidth: Self.columnWidth, idealWidth: Self.columnWidth, maxWidth: .infinity, maxHeight: 0)
            }
        }
    }

    private static var columnWidth: CGFloat { 300 }
    #endif

    private func column(_ items: [Item]) -> some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                VStack(spacing: 0) {
                    row(item)
                    if item.id != items.last?.id {
                        Divider().padding(.leading, ruleInset)
                    }
                }
            }
        }
    }
}

/// A song in a room's list: its cover, or its place in a sequence, its name and artist, and
/// one fact at the trailing edge. The size of a suggestion's row, so loading rows hold it.
struct RoomSongRow: View {
    let title: String
    let artist: String
    let cover: CoverArt
    /// Its place, where the order is the point.
    var number: Int?
    var detail: String?
    var isCurrent = false
    var isPlayable = true

    @Environment(PlayerModel.self) private var player
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var coverSide: CGFloat = SuggestionRow.cover
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            if let number {
                Text(number, format: .number)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: Self.numberWidth, alignment: .trailing)
            }
            CoverImage(cover: cover, size: min(coverSide, 72))
                .overlay {
                    if isCurrent || isHovered {
                        RoundedRectangle(cornerRadius: CoverImage.radius(for: min(coverSide, 72)), style: .continuous)
                            .fill(.black.opacity(0.4))
                        if isCurrent {
                            PlayingWaveform(isActive: player.isPlaying, color: .white)
                                .font(.subheadline.weight(.semibold))
                        } else {
                            Image(systemName: "play.fill")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                        }
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                Text(artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
            }
            Spacer(minLength: 8)
            if let detail, !typeSize.isAccessibilitySize {
                Text(detail)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .frame(minHeight: SuggestionRow.rowHeight)
        .opacity(isPlayable ? 1 : 0.45)
        .contentShape(.rect)
        #if os(macOS)
        .padding(.horizontal, 6)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.primary.opacity(isHovered ? 0.06 : 0))
        }
        .padding(.horizontal, -6)
        .onHover { hovering in
            withAnimation(PlayMotion.hover) { isHovered = hovering && isPlayable }
        }
        #endif
        .accessibilityElement(children: .combine)
    }

    /// Where a row's words start, for the rule under it.
    static var textInset: CGFloat { SuggestionRow.cover + 12 }
    /// The same, in a numbered row.
    static var numberedTextInset: CGFloat { textInset + numberWidth + 12 }
    static let numberWidth: CGFloat = 22
}

/// What a section says in place of its rows: why it's empty and, where something can be done
/// about it, the button that does it.
struct RoomNote: View {
    let text: String
    var symbol: String?
    var action: RoomNoteAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                if let symbol {
                    Image(systemName: symbol)
                }
            }
            .labelStyle(RoomNoteLabelStyle(showsIcon: symbol != nil))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(.bordered)
                    #if os(macOS)
                    .controlSize(.regular)
                    #endif
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(.vertical, 6)
    }
}

/// The button under a room's note.
struct RoomNoteAction {
    let title: LocalizedStringKey
    let run: () -> Void
}

private struct RoomNoteLabelStyle: LabelStyle {
    let showsIcon: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if showsIcon { configuration.icon }
            configuration.title
        }
    }
}

/// "Show More" and "Show Less" under a list, in the room's colour.
struct RoomShowMore: View {
    @Binding var isShowingAll: Bool
    let ink: LegibleInk

    var body: some View {
        Button {
            withAnimation(PlayMotion.row) { isShowingAll.toggle() }
        } label: {
            Text(isShowingAll ? "Show Less" : "Show More")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ink)
                .frame(maxWidth: .infinity, minHeight: Self.height)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    #if os(macOS)
    private static var height: CGFloat { 32 }
    #else
    private static var height: CGFloat { 44 }
    #endif
}

/// A small text button at a section's trailing edge, in the room's colour: Play, Shuffle.
struct RoomSectionAction: View {
    let title: LocalizedStringKey
    let symbol: String
    let ink: LegibleInk
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ink)
                .frame(minHeight: Self.height)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    #if os(macOS)
    private static var height: CGFloat { 28 }
    #else
    private static var height: CGFloat { 44 }
    #endif
}
