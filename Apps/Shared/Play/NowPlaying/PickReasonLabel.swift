import SwiftUI
import TracksCore

/// Why a song a live mix picked came up, in a line under it: "New to you", "One you play on
/// drives". The symbol sits in a column of its own width, so the words line up whichever
/// symbol leads them. Takes its colour from where it sits.
struct PickReasonLabel: View {
    let reason: LiveMix.Reason
    /// Two where there's room to wrap rather than cut it short at large text sizes.
    var lineLimit = 1
    @ScaledMetric(relativeTo: .caption) private var symbolWidth: CGFloat = 14

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: reason.symbol)
                .font(.caption2.weight(.semibold))
                .imageScale(.medium)
                .frame(width: symbolWidth)
            Text(reason.line)
                .font(.caption.weight(.medium))
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: lineLimit > 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reason.line)
    }
}

#Preview("Every reason") {
    let reasons: [LiveMix.Reason] = [
        .newFind, .newFromYourArtist, .newFindLike("Mara Solis"), .onTheRoad, .aroundNow, .leaningInto("Hip-Hop"),
        .oldFavorite(lastHeard: .now.addingTimeInterval(-200 * 86_400)), .mostPlayed, .moreOf("Alternative"), .moreLike("Nova Harbor"),
        .probing, .goesWith("Paper Lanterns"),
    ]
    VStack(alignment: .leading, spacing: 10) {
        ForEach(reasons.enumerated(), id: \.offset) { _, reason in
            PickReasonLabel(reason: reason)
        }
    }
    .foregroundStyle(.white.opacity(0.6))
    .padding()
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(red: 0.45, green: 0.12, blue: 0.2))
}
