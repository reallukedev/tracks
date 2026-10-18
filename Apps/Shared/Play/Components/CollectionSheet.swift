import SwiftUI

#if os(macOS)
/// A short task's sheet on the Mac: its title and what it's about in the content, not in a
/// toolbar band, the task in the middle, and its buttons trailing in a bar at the foot.
struct CollectionSheetLayout<Content: View, Actions: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2.bold())
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 14)
            content
            HStack(spacing: 8) {
                actions
            }
            .padding(20)
        }
    }
}

/// Search inside a Mac sheet: a plain field drawn as a search field, since `.searchable` would
/// put it in the window's toolbar behind the sheet.
struct CollectionSheetSearchField: View {
    let prompt: LocalizedStringKey
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear Search")
                .accessibilityLabel("Clear Search")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color.cardFill, in: .rect(cornerRadius: 7, style: .continuous))
    }
}
#endif
