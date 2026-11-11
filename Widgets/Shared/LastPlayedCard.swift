import SwiftUI

/// One song with its cover. The Last Played widget, and the leading half of the Today widget
/// when Up Next is on.
struct LastPlayedCard: View {
    let capture: WidgetCapture

    var body: some View {
        // At large text sizes, drop the title's second line first, then the cover.
        ViewThatFits(in: .vertical) {
            card(showsArtwork: true, titleLines: 2)
            card(showsArtwork: true, titleLines: 1)
            card(showsArtwork: false, titleLines: 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Last played: \(capture.title) by \(capture.artistName)")
    }

    private func card(showsArtwork: Bool, titleLines: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsArtwork {
                WidgetArtwork(data: capture.artwork, size: 56)
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(capture.title)
                    .font(.headline)
                    .lineLimit(titleLines)
                Text(capture.artistName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // Redacted on a locked device when that's asked for. The redaction keeps the
            // text's frame, so `ViewThatFits` picks the same card either way.
            .privacySensitive()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
