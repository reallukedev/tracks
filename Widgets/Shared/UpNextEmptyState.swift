import SwiftUI

/// Up Next with nothing in it. Shown rather than hidden, or the setting would look broken,
/// and it explains the section since this is often the first state people see.
struct UpNextEmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("All Caught Up", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Radio songs you haven't played back yet appear here.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
    }
}
