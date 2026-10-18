import SwiftUI
import TracksCore

/// Things to try remembering a song by, before anything is typed: each one a search that
/// finds something.
struct RecallSuggestionsSection: View {
    let phrases: [String]
    let search: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SearchSectionTitle("Search by When You Heard It")
                .padding(.horizontal, PlayMetrics.margin)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(phrases, id: \.self) { phrase in
                        SearchChip(title: phrase, systemImage: Self.symbol(for: phrase)) {
                            search(phrase)
                        }
                    }
                }
            }
            .contentMargins(.horizontal, PlayMetrics.margin, for: .scrollContent)
            .scrollIndicators(.hidden)
        }
    }

    private static func symbol(for phrase: String) -> String {
        if phrase.localizedStandardContains("radio") { return "dot.radiowaves.left.and.right" }
        if phrase.localizedStandardContains("night") { return "moon" }
        if phrase.localizedStandardContains("morning") { return "sunrise" }
        if phrase.localizedStandardContains("afternoon") { return "sun.max" }
        if phrase.localizedStandardContains("summer") { return "sun.horizon" }
        return "calendar"
    }
}

/// What a remembered search understood, above what it found, with Play for all of it.
struct RecallHeader: View {
    let title: RecallTitle
    /// Nil when nothing found can play.
    let play: (() -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // Play goes under the title at the largest sizes, which need the whole width.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
        layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(title.title)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                if let detail = title.detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let play {
                Button("Play", systemImage: "play.fill", action: play)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .fixedSize()
            }
        }
    }
}

/// In the other scopes, a way to the history when what's typed is a time: Apple Music has
/// no idea what you heard last Tuesday.
struct HistoryRecallHint: View {
    let query: String
    let searchHistory: () -> Void

    var body: some View {
        let recall = HistoryRecall.parse(query)
        // Only a time: "jazz radio", "90s" and "after hours" are fair searches of a catalog.
        if recall.interval != nil || recall.partOfDay != nil || recall.weekday != nil {
            let title = RecallTitle(recall, anchor: recall.relation?.anchor.localizedCapitalized)
            Button(action: searchHistory) {
                HStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Search Your History")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                        Text([title.title, title.detail].compactMap(\.self).joined(separator: " · "))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.forward")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 14, style: .continuous))
                .contentShape(.rect(cornerRadius: 14))
            }
            .buttonStyle(.pressable)
            .padding(.horizontal, PlayMetrics.margin)
            .accessibilityElement(children: .combine)
        }
    }
}

#if DEBUG
#Preview("Recall parts") {
    ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            RecallSuggestionsSection(phrases: ["This Morning", "Last Night", "Radio This Week", "In September"]) { _ in }
            RecallHeader(title: RecallTitle(HistoryRecall.parse("radio last week"), anchor: nil)) {}
                .padding(.horizontal, PlayMetrics.margin)
            RecallHeader(title: RecallTitle(HistoryRecall.parse("90s jazz on the radio late at night in september"), anchor: nil), play: nil)
                .padding(.horizontal, PlayMetrics.margin)
            RecallHeader(title: RecallTitle(HistoryRecall.parse("after x"), anchor: "Everything I Meant to Say on the Drive Home, Pt. 2")) {}
                .padding(.horizontal, PlayMetrics.margin)
            HistoryRecallHint(query: "last tuesday evening") {}
        }
        .padding(.vertical, 16)
    }
}
#endif
