import SwiftUI

extension View {
    /// A song's row on a collection's page on iPhone: the song's menu behind a long press, and
    /// the same menu behind "…" at the row's end, as Music's rows have.
    func trackMenu<Items: View>(@ViewBuilder _ items: () -> Items) -> some View {
        modifier(TrackMenuModifier(items: items()))
    }
}

private struct TrackMenuModifier<Items: View>: ViewModifier {
    let items: Items

    func body(content: Content) -> some View {
        HStack(spacing: 0) {
            content
            #if os(iOS)
            Menu {
                items
            } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .tint(.secondary)
            .menuIndicator(.hidden)
            .accessibilityLabel("More")
            #endif
        }
        .contextMenu { items }
    }
}

/// What's in a collection's list when there are no songs to show yet: a sentence that says
/// what happened or what's coming, and the button that does the next thing. It stands in the
/// list's own place, never floating over it.
struct CollectionMessage<Actions: View>: View {
    let text: String
    var systemImage: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 12) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            actions
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, PlayMetrics.margin)
        #if os(iOS)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        #endif
    }
}

extension CollectionMessage where Actions == EmptyView {
    init(text: String, systemImage: String? = nil) {
        self.init(text: text, systemImage: systemImage) { EmptyView() }
    }
}

/// The small print under a collection's songs: its release, its length, its copyright, and
/// any note about songs left out.
struct CollectionFooter: View {
    let lines: [String]

    var body: some View {
        let lines = lines.filter { !$0.isEmpty }
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(lines, id: \.self) { Text($0) }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
    }
}
