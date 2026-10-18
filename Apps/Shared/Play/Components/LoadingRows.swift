import SwiftUI

/// Rows in the shape of what's coming, while it loads. Still, not a spinner: a page opens
/// straight to its layout, and the songs take their places when they arrive.
struct LoadingRows: View {
    var count = 6
    /// Tracks on an album have a number where a playlist's have a cover.
    var showsCover = true
    /// A rule under each but the last, inset to the text, as the rows it stands for have.
    var showsDividers = true

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                LoadingRow(showsCover: showsCover, width: Self.widths[index % Self.widths.count])
                if showsDividers, index < count - 1 {
                    Divider()
                        .padding(.leading, showsCover ? LoadingRow.cover + 12 : 36)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Loading"))
    }

    /// Titles of different lengths, so the rows read as a list rather than a pattern.
    private static let widths: [CGFloat] = [0.62, 0.48, 0.7, 0.4, 0.56, 0.66]
}

/// One row's shape: a cover or a number, a title and a line under it, the size of a song row.
struct LoadingRow: View {
    var showsCover = true
    var width: CGFloat = 0.6

    /// A song row's cover and height, so the rows that arrive take the shapes' places exactly.
    static let cover = SuggestionRow.cover
    static let height = SuggestionRow.rowHeight

    var body: some View {
        HStack(spacing: 12) {
            if showsCover {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(.secondarySystemFill))
                    .frame(width: Self.cover, height: Self.cover)
            } else {
                Capsule()
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 14, height: 10)
                    .frame(width: 24)
            }
            GeometryReader { proxy in
                VStack(alignment: .leading, spacing: 8) {
                    Capsule().fill(Color(.secondarySystemFill)).frame(width: proxy.size.width * width * 0.7, height: 11)
                    Capsule().fill(Color(.tertiarySystemFill)).frame(width: proxy.size.width * width * 0.45, height: 9)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .frame(height: Self.height)
        .accessibilityHidden(true)
    }
}

/// In place of ``LoadingRow`` when the next page couldn't be fetched, so a dropped connection
/// doesn't pass for the end of the list.
struct LoadMoreFailedRow: View {
    var text: LocalizedStringKey = "Couldn't load more songs."
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Try Again", action: retry)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .frame(minHeight: LoadingRow.height)
    }
}
