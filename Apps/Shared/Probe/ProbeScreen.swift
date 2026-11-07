import SwiftUI
import TracksCore

/// The phase 0 diagnostic screen. Dumps what the player reports so radio and on-demand
/// playback can be told apart from real data. Reachable from a DEBUG-only entry point.
struct ProbeScreen: View {
    @Bindable var model: ProbeModel

    var body: some View {
        List {
            environmentSection
            controlsSection
            writePathSection
            logSection
        }
        .navigationTitle("Probe")
        .toolbar {
            ToolbarItem {
                ShareLink(item: model.log.exportText) {
                    Label("Export log", systemImage: "square.and.arrow.up")
                }
                .disabled(model.log.entries.isEmpty)
            }
        }
        .task { await model.loadEnvironment() }
    }

    // MARK: - Sections

    private var environmentSection: some View {
        Section("Environment") {
            ForEach(model.environment) { row in
                LabeledContent(row.key) {
                    Text(row.value)
                        .foregroundStyle(.secondary)
                        // Wrap long values so they stay readable on a phone.
                        .multilineTextAlignment(.trailing)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var controlsSection: some View {
        Section("Sampling") {
            Toggle("Sample every second", isOn: $model.isSampling)
                .accessibilityHint("Records what the music player reports, once per second.")

            LabeledContent("Entries", value: "\(model.log.entries.count)")

            Button("Clear log", role: .destructive) { model.log.clear() }
                .disabled(model.log.entries.isEmpty)
        }
    }

    private var writePathSection: some View {
        Section {
            Button("Create probe playlist") {
                Task { await model.testCreatePlaylist() }
            }
            .disabled(model.isWriting)

            Button("Add current song to it") {
                Task { await model.testAddCurrentSong() }
            }
            .disabled(model.isWriting || model.probePlaylistID == nil)

            if let id = model.probePlaylistID {
                LabeledContent("Playlist ID", value: id)
            }
        } header: {
            Text("Playlist write path")
        } footer: {
            Text("""
                Creates a throwaway playlist and adds the song playing right now, using the \
                Apple Music REST API. This is the only playlist path that works on both \
                platforms, so it is worth proving before anything depends on it. Delete the \
                playlist afterwards.
                """)
        }
    }

    private var logSection: some View {
        Section("Log") {
            if model.log.entries.isEmpty {
                ContentUnavailableView(
                    "Nothing captured yet",
                    systemImage: "waveform",
                    description: Text("Start sampling, then play a radio station.")
                )
            } else {
                // Newest first.
                ForEach(model.log.entries.reversed()) { entry in
                    ProbeEntryRow(entry: entry)
                }
            }
        }
    }
}

private struct ProbeEntryRow: View {
    let entry: ProbeEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.category.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(entry.category == .error ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
                Spacer()
                Text(entry.timestamp, format: .dateTime.hour().minute().second())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(entry.headline)
                .font(.callout)
            ForEach(entry.fields, id: \.key) { field in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(field.key)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text(field.value)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.headline)
        .accessibilityValue(entry.fields.map { "\($0.key): \($0.value)" }.joined(separator: ", "))
    }
}
