import SwiftUI
import TracksCore

/// The page's leading edge, shared by the large title, section headers and the first tile of
/// every shelf. Roomier on the Mac, where a window is wider than a phone and read from further.
enum PlayMetrics {
    #if os(macOS)
    static let margin: CGFloat = 28
    static let shelfSpacing: CGFloat = 18
    static let tile: CGFloat = 176
    /// Between one section and the next.
    static let sectionSpacing: CGFloat = 36
    #else
    static let margin: CGFloat = 20
    static let shelfSpacing: CGFloat = 12
    static let tile: CGFloat = 160
    static let sectionSpacing: CGFloat = 28
    #endif
}

/// How Play moves, named by what's moving, so every page moves the same way. Under Reduce
/// Motion, views use `nil` or a cross-fade instead.
enum PlayMotion {
    /// A control answering a press.
    static let press = Animation.snappy(duration: 0.14)
    /// The pointer arriving over something on the Mac.
    static let hover = Animation.easeOut(duration: 0.13)
    /// A number or a word changing in place.
    static let value = Animation.snappy(duration: 0.3)
    /// A panel, a list or a page's part opening or closing.
    static let panel = Animation.smooth(duration: 0.3)
    /// Rows arriving, leaving or moving.
    static let row = Animation.smooth(duration: 0.28)
    /// A cover's colour settling onto the page.
    static let tint = Animation.easeOut(duration: 0.4)
    /// The sleeve turning over: the one flourish, from a tap or click only.
    static let flip = Animation.spring(duration: 0.5, bounce: 0.12)
}

/// A titled row of tiles that scrolls sideways, as on Music's Home. On the Mac, arrows at
/// either end page through it while the pointer is over it, as Music's shelves do.
struct Shelf<Items: RandomAccessCollection, Tile: View, Trailing: View>: View where Items.Element: Identifiable {
    let title: String
    let items: Items
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var tile: (Items.Element) -> Tile
    #if os(macOS)
    /// The tiles wholly in view, in order, for the arrows to page from.
    @State private var visible: [Items.Element.ID] = []
    @State private var isHovering = false
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AdaptiveStack(verticalAlignment: .firstTextBaseline, spacing: 4) {
                Text(title)
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                trailing
                    .font(.subheadline)
            }
            .padding(.horizontal, PlayMetrics.margin)

            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: PlayMetrics.shelfSpacing) {
                        ForEach(items) { item in
                            tile(item)
                                .id(item.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, PlayMetrics.margin, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
                #if os(macOS)
                .onScrollTargetVisibilityChange(idType: Items.Element.ID.self, threshold: 0.95) { visible = $0 }
                .overlay {
                    if isHovering {
                        pageArrows(proxy)
                    }
                }
                // After the arrows, so moving onto one doesn't count as leaving the shelf.
                .onHover { hovering in
                    withAnimation(PlayMotion.hover) { isHovering = hovering }
                }
                #endif
            }
        }
    }

    #if os(macOS)
    private func pageArrows(_ proxy: ScrollViewProxy) -> some View {
        let ids = items.map(\.id)
        let first = visible.first.flatMap { ids.firstIndex(of: $0) }
        let last = visible.last.flatMap { ids.firstIndex(of: $0) }
        return HStack {
            if let first, first > 0 {
                ShelfArrow(systemImage: "chevron.backward", label: "Previous") {
                    // The tile before the first in view comes in at the far edge: a page back.
                    proxy.scrollTo(ids[first - 1], anchor: .trailing)
                }
            }
            Spacer()
            if let last, last < ids.count - 1 {
                ShelfArrow(systemImage: "chevron.forward", label: "Next") {
                    proxy.scrollTo(ids[last + 1], anchor: .leading)
                }
            }
        }
        .padding(.horizontal, 8)
        .transition(.opacity)
    }
    #endif
}

#if os(macOS)
/// A round glass arrow at the end of a shelf.
private struct ShelfArrow: View {
    let systemImage: String
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(label, systemImage: systemImage) {
            withAnimation(PlayMotion.panel, action)
        }
        .labelStyle(.iconOnly)
        .font(.body.weight(.semibold))
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .help(Text(label))
    }
}
#endif

extension Shelf where Trailing == EmptyView {
    init(title: String, items: Items, @ViewBuilder tile: @escaping (Items.Element) -> Tile) {
        self.title = title
        self.items = items
        self.trailing = EmptyView()
        self.tile = tile
    }
}

/// A square cover with a title and a line under it, for a shelf.
struct TileLabel<Cover: View>: View {
    let title: String
    let subtitle: String?
    @ScaledMetric(relativeTo: .subheadline) private var width = PlayMetrics.tile
    @ViewBuilder var cover: (CGFloat) -> Cover

    var body: some View {
        let side = min(width, 220)
        VStack(alignment: .leading, spacing: 6) {
            cover(side)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(width: side, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// Covers and cards shrink slightly under a finger, as Music's do.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.snappy(duration: 0.14), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}

/// "LIVE", on a live station's cover, in Music's red.
struct LiveBadge: View {
    var body: some View {
        Text("Live")
            .textCase(.uppercase)
            .font(.caption2.weight(.heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.red, in: .rect(cornerRadius: 4, style: .continuous))
    }
}
