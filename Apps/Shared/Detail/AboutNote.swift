import SwiftUI

/// What Apple Music's editors wrote about an artist, album or song: the first few lines, and
/// More for the rest, in a sheet on iPhone and a popover on the Mac, as Music's About does.
struct AboutNote: View {
    /// Whose note it is, for the title over the whole of it.
    let title: String
    let text: String
    var lineLimit = 4

    @State private var showsAll = false

    var body: some View {
        if hasMore {
            Button {
                showsAll = true
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    note
                    Text("More")
                        .font(Self.moreFont)
                        .foregroundStyle(.tint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows all of it")
            #if os(iOS)
            .sheet(isPresented: $showsAll) {
                AboutNoteSheet(title: title, text: text)
            }
            #else
            .popover(isPresented: $showsAll, arrowEdge: .bottom) {
                AboutNotePopover(title: title, text: text)
            }
            .help("Read More")
            #endif
        } else {
            note
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var note: some View {
        Text(text)
            .foregroundStyle(.primary)
            .lineLimit(lineLimit)
            .multilineTextAlignment(.leading)
    }

    /// Longer than the lines shown can hold, near enough: a note of a sentence or two reads
    /// whole, and a biography gets More. Measuring the text instead would feed a size back
    /// into the layout.
    private var hasMore: Bool {
        text.count > lineLimit * 42 || text.contains("\n")
    }

    #if os(iOS)
    private static let moreFont = Font.subheadline.weight(.semibold)
    #else
    private static let moreFont = Font.callout.weight(.semibold)
    #endif
}

extension AboutNote {
    /// Apple Music's note as plain words: without the markup some notes carry, and with no
    /// more than one blank line between paragraphs. Nil when nothing's left.
    static func clean(_ note: String?) -> String? {
        guard var text = note else { return nil }
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

#if os(iOS)
/// All of a note, on iPhone: a sheet that opens halfway and pulls up for a long biography.
private struct AboutNoteSheet: View {
    let title: String
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
            .navigationTitle(title)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", role: .confirm) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
#else
/// All of a note, on the Mac: a popover from More, as wide as a comfortable line, scrolling
/// when a biography runs long.
private struct AboutNotePopover: View {
    let title: String
    let text: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .frame(width: 420)
        .frame(maxHeight: 480)
    }
}
#endif

/// A few labelled facts side by side, as Music's About lists an artist's genre and hometown:
/// a small label over each value. They stack at the largest text sizes.
struct AboutFacts: View {
    struct Fact: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    let facts: [Fact]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 32))
        layout {
            ForEach(facts) { fact in
                VStack(alignment: .leading, spacing: 2) {
                    Text(fact.label)
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    Text(fact.value)
                        .font(Self.valueFont)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    #if os(iOS)
    private static let valueFont = Font.subheadline
    #else
    private static let valueFont = Font.callout
    #endif
}
