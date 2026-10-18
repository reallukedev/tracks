import SwiftUI
import SwiftData
import TracksCore

/// Which stations Tracks captures from. Edits the exclusion set ``CapturePolicy`` reads.
///
/// Stations are picked from a list rather than typed, because an exclusion only works if
/// it matches the name the platform reports exactly.
struct StationExclusionsSection: View {
    /// Most recently heard first.
    @Query(sort: \Station.lastSeenAt, order: .reverse) private var stations: [Station]

    /// A local copy of the stored set, saved on change. `CaptureSettings` isn't observable,
    /// so a `Toggle` bound straight to it would snap back after each tap.
    @State private var excluded = CaptureSettings().excludedStations

    private let settings = CaptureSettings()

    var body: some View {
        Section {
            ForEach(names, id: \.self) { name in
                Toggle(name, isOn: capturing(name))
            }
        } header: {
            Text("Stations")
        } footer: {
            Text("""
                Turn a station off to stop keeping what it plays. Songs already kept from it \
                stay in your history.
                """)
        }
        .onChange(of: excluded) { _, names in
            settings.excludedStations = names
        }
        .onSettingsChangedRemotely { excluded = settings.excludedStations }
    }

    /// Apple's live stations, then the others Tracks has heard. See ``AppleMusicStations``.
    private var names: [String] {
        AppleMusicStations.choices(heard: stations.map(\.name), excluded: excluded)
    }

    /// On means capturing, so the switch doesn't read as a double negative.
    private func capturing(_ name: String) -> Binding<Bool> {
        Binding(
            get: { !excluded.contains(name) },
            // Local state only; `onChange(of: excluded)` saves it.
            set: { isCapturing in
                if isCapturing {
                    excluded.remove(name)
                } else {
                    excluded.insert(name)
                }
            }
        )
    }
}
