import SwiftUI
import TracksCore

/// The top of a mood's or genre's page: its field, its covers in its own arrangement, its name
/// set in its own type, a line on what it is, one fact from your listening, and its controls.
/// On the Mac the covers sit beside the words once the window has room for both.
struct RoomHero<Actions: View>: View {
    let style: RoomStyle
    let title: String
    let tagline: String
    /// One fact from your listening, or nil while it's worked out or when there's none.
    let facts: String?
    let covers: [CoverArt]
    var isLoading = false
    @ViewBuilder var actions: Actions

    #if os(iOS)
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 46
    #endif

    var body: some View {
        content
            .foregroundStyle(.white)
            .padding(.horizontal, PlayMetrics.margin)
            .padding(.top, Self.top)
            .padding(.bottom, Self.bottom + RoomField.fade)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { RoomField(style: style) }
    }

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        // Beside each other once there's room, larger in a big window; the covers on top in
        // a narrow one.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 48) {
                words(titleSize: 76)
                    .frame(minWidth: 600, idealWidth: 600, maxWidth: 720, alignment: .leading)
                Spacer(minLength: 0)
                mosaic(scale: 1.45)
            }
            HStack(alignment: .center, spacing: 40) {
                words(titleSize: titleSize)
                    .frame(minWidth: 320, idealWidth: 320, maxWidth: 560, alignment: .leading)
                Spacer(minLength: 0)
                mosaic(scale: 1)
            }
            stacked
        }
        #else
        stacked
        #endif
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 20) {
            mosaic(scale: 1)
                .frame(maxWidth: .infinity)
            words(titleSize: titleSize)
        }
    }

    private func mosaic(scale: CGFloat) -> some View {
        CoverMosaic(covers: covers, layout: style.covers, side: Self.side(for: style.covers) * scale, symbol: style.symbol, isLoading: isLoading)
    }

    private func words(titleSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(style.title.font(size: titleSize))
                .tracking(style.title.tracking)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .accessibilityAddTraits(.isHeader)
            Text(tagline)
                .font(.title3)
                .opacity(0.92)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            Group {
                if let facts {
                    Text(facts)
                        .transition(.opacity)
                } else if isLoading {
                    Capsule()
                        .fill(.white.opacity(0.18))
                        .frame(width: 180, height: 10)
                        .frame(maxHeight: .infinity, alignment: .center)
                        .accessibilityHidden(true)
                }
            }
            .font(.subheadline.weight(.medium))
            .opacity(0.82)
            .frame(minHeight: Self.factsHeight, alignment: .leading)
            .padding(.top, 10)
            .animation(.easeOut(duration: 0.2), value: facts)
            actions
                .padding(.top, 18)
        }
    }

    #if os(macOS)
    private var titleSize: CGFloat { 60 }
    private static var top: CGFloat { 28 }
    private static var bottom: CGFloat { 8 }
    private static var factsHeight: CGFloat { 16 }
    #else
    private static var top: CGFloat { 4 }
    private static var bottom: CGFloat { 0 }
    private static var factsHeight: CGFloat { 18 }
    #endif

    /// One cover's size in an arrangement: a lone cover larger, a crate's smaller.
    static func side(for layout: RoomStyle.Covers) -> CGFloat {
        #if os(macOS)
        let base: CGFloat = 132
        #else
        let base: CGFloat = 116
        #endif
        return switch layout {
        case .single: base * 1.3
        case .pair: base * 1.12
        case .grid: base * 1.05
        case .fan, .pile, .strip: base
        }
    }
}

/// Play and Shuffle on a room's field: Play a white capsule in the room's colour, Shuffle a
/// veil, side by side, stacked at the largest text sizes. Anything after them, such as a
/// timer, sits on their row.
struct RoomPlayButtons<Extra: View>: View {
    let style: RoomStyle
    let playTitle: LocalizedStringKey
    let playSymbol: String
    let canPlay: Bool
    /// Nil hides Shuffle: there's nothing of yours to shuffle.
    let shuffle: (() -> Void)?
    let play: () -> Void
    @ViewBuilder var extra: Extra
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))
        layout {
            Button(action: play) {
                Label(playTitle, systemImage: playSymbol)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(maxWidth: Self.fills ? .infinity : nil)
            }
            .buttonStyle(.stagePrimary(tint: style.base.mix(with: .black, by: 0.25)))
            .disabled(!canPlay)
            if let shuffle {
                Button(action: shuffle) {
                    Label("Shuffle", systemImage: "shuffle")
                        .frame(maxWidth: Self.fills ? .infinity : nil)
                }
                .buttonStyle(.stageSecondary)
            }
            extra
        }
    }

    #if os(macOS)
    private static var fills: Bool { false }
    #else
    private static var fills: Bool { true }
    #endif
}

extension RoomPlayButtons where Extra == EmptyView {
    init(style: RoomStyle, playTitle: LocalizedStringKey, playSymbol: String, canPlay: Bool, shuffle: (() -> Void)?, play: @escaping () -> Void) {
        self.init(style: style, playTitle: playTitle, playSymbol: playSymbol, canPlay: canPlay, shuffle: shuffle, play: play) { EmptyView() }
    }
}

/// A round veil button on a room's field, for a menu beside Play and Shuffle.
struct RoomRoundMenu<Items: View>: View {
    let title: LocalizedStringKey
    let symbol: String
    var isOn = false
    @ViewBuilder var items: Items
    @ScaledMetric(relativeTo: .headline) private var side = StageButtonStyle.height

    var body: some View {
        Menu {
            items
        } label: {
            Image(systemName: symbol)
                .font(Self.font)
                .symbolVariant(isOn ? .fill : .none)
                .foregroundStyle(.white)
                .frame(width: side, height: side)
                .background(.white.opacity(isOn ? 0.32 : 0.2), in: .circle)
                .contentShape(.circle)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text(title))
        #if os(macOS)
        .help(Text(title))
        #endif
    }

    #if os(macOS)
    private static var font: Font { Font.body.weight(.semibold) }
    #else
    private static var font: Font { Font.headline }
    #endif
}
