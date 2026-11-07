import SwiftUI
import TracksCore

/// Bringing the Last.fm history into Tracks: one button that imports, stops, continues or
/// syncs, and a line saying how far it has got.
///
/// Takes the state rather than ``LastFMHistorySync``, so previews can show every state
/// without reading the real account.
struct LastFMHistorySection: View {
    var state: LastFMHistoryWords.State
    var action: () -> Void

    var body: some View {
        Section {
            #if os(macOS)
            SettingsDetailRow(
                title: Text(LastFMHistoryWords.title),
                detail: Text(LastFMHistoryWords.detail(state))
            ) {
                Button(LastFMHistoryWords.button(state), action: action)
            }
            #else
            Button(action: action) {
                // An `HStack` rather than `LabeledContent`, which would style the row as a
                // read-out and lose the button's tint. The spinner sits where a disclosure
                // would, so the title doesn't move when it appears.
                HStack {
                    Text(LastFMHistoryWords.action(state))
                    Spacer()
                    if state.isImporting {
                        ProgressView()
                    }
                }
            }
            #endif
            if case .importing(let read, let total?, _) = state, total > 0 {
                ProgressView(value: Double(min(read, total)), total: Double(total))
                    .accessibilityLabel("Scrobbles read")
            }
        } header: {
            Text("History")
        } footer: {
            #if os(iOS)
            Text(LastFMHistoryWords.detail(state))
                .contentTransition(.opacity)
            #endif
        }
    }
}

#if DEBUG
#Preview("Not imported") {
    Form { LastFMHistorySection(state: .notImported) {} }
        .formStyle(.grouped)
}

#Preview("Importing") {
    Form { LastFMHistorySection(state: .importing(read: 3_400, total: 52_000, added: 3_100)) {} }
        .formStyle(.grouped)
}

#Preview("Stopped") {
    Form { LastFMHistorySection(state: .stopped(added: 12_345)) {} }
        .formStyle(.grouped)
}

#Preview("Up to date") {
    Form { LastFMHistorySection(state: .upToDate(lastSynced: .now.addingTimeInterval(-300), added: 48_210)) {} }
        .formStyle(.grouped)
}

#Preview("Failed") {
    Form { LastFMHistorySection(state: .failed("Last.fm returned HTTP 503.")) {} }
        .formStyle(.grouped)
}
#endif
