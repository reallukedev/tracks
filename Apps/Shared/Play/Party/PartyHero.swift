import SwiftUI
import TracksCore

/// The top of Party: the party's field running up under the bar, its symbol, the page's name,
/// a line on the party, and the chips to choose another. Choosing one recolours the field and
/// swaps the symbol and the line together.
struct PartyHero: View {
    @Binding var vibe: PartyVibe
    let vibes: [PartyVibe]
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: vibe.symbol)
                    .font(.system(size: 28, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(height: 34, alignment: .bottomLeading)
                    .accessibilityHidden(true)
                Text("Party")
                    .font(.system(size: titleSize, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .padding(.top, 8)
                    .accessibilityAddTraits(.isHeader)
                Text(vibe.tagline)
                    .font(.title3)
                    .opacity(0.9)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                    .contentTransition(.opacity)
            }
            .padding(.horizontal, PlayMetrics.margin)

            PartyVibeChips(selection: $vibe, vibes: vibes)
        }
        .foregroundStyle(.white)
        .padding(.top, PartyMetrics.heroTop)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            PartyField(vibe: vibe)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: vibe.symbol)
                        .font(.system(size: 220, weight: .bold))
                        .foregroundStyle(.white.opacity(0.1))
                        .contentTransition(.symbolEffect(.replace))
                        .rotationEffect(.degrees(-12))
                        .offset(x: 60, y: 40)
                        .accessibilityHidden(true)
                }
                .clipped()
                // Into the page at its foot, as the mood pages' fields do: a fade of fixed
                // length below the chips, however tall the field is.
                .mask {
                    VStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 44)
                    }
                }
                // Up under the bar and into any pull past the top.
                .padding(.top, -400)
        }
        // Colours, symbol and line change together, from the chip that was tapped. A colour
        // change isn't movement, so it stays under Reduce Motion.
        .animation(.smooth(duration: 0.35), value: vibe)
    }
}
