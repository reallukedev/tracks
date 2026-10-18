import SwiftUI

/// A rounded panel for Summary content.
struct Card<Content: View>: View {
    var padding: CGFloat = Metrics.cardPadding
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background { CardBackground() }
    }
}

struct CardBackground: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
        #if os(iOS)
        CardFill().clipShape(shape)
        #else
        CardFill()
            .clipShape(shape)
            .overlay { shape.strokeBorder(.separator.opacity(0.6), lineWidth: 0.5) }
        #endif
    }
}

/// A card's fill alone, for something that has to match the card it sits on.
struct CardFill: View {
    var body: some View {
        #if os(iOS)
        Color(.secondarySystemGroupedBackground)
        #else
        Rectangle().fill(.background.secondary)
        #endif
    }
}

extension View {
    /// The background behind a column of cards, applied to its scroll view.
    ///
    /// On the Mac it's the scroll view's own background. Painting a colour behind the scroll
    /// view instead gave the title bar a band of its own, a different shade with a hairline
    /// under it; a scroll view that draws its background lets the title bar blend into it.
    func groupedBackground() -> some View {
        #if os(iOS)
        background(GroupedBackground())
        #else
        scrollContentBackground(.visible)
        #endif
    }
}

/// The background behind a column of cards.
struct GroupedBackground: View {
    var body: some View {
        #if os(iOS)
        Color(.systemGroupedBackground).ignoresSafeArea()
        #else
        Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
        #endif
    }
}

/// A section title with an optional trailing link, in the style of Health and Fitness.
struct SectionHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var trailing: Trailing

    var body: some View {
        AdaptiveStack(verticalAlignment: .firstTextBaseline, spacing: 4) {
            Text(title)
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            trailing
                .font(.subheadline)
                .buttonStyle(SectionLinkButtonStyle())
                .foregroundStyle(.tint)
        }
        .padding(.horizontal, 4)
    }
}

/// Plain text that's easy to hit. "See All" in `.subheadline` is about 20 points tall, and a
/// finger needs 44. The extra room is an invisible area behind the text, so the header
/// doesn't get any taller or move.
private struct SectionLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.4 : 1)
            #if os(iOS)
            .background {
                // Centred on the text and allowed to spill past it. SwiftUI hit-tests the
                // spill-over, though layout ignores it.
                Color.clear
                    .frame(minWidth: Self.minimumTarget, minHeight: Self.minimumTarget)
                    .padding(.horizontal, 8)
                    .contentShape(.rect)
            }
            #endif
    }

    private static let minimumTarget: CGFloat = 44
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: LocalizedStringKey) {
        self.title = title
        self.trailing = EmptyView()
    }
}

/// Small grey caption above a card's main value, like "LISTENING" in Screen Time.
struct CardLabel: View {
    let title: LocalizedStringKey
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        Group {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(tint)
    }
}
