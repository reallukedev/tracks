import SwiftUI
import TracksCore

/// Finds covers that no longer load and fetches them again.
///
/// Covers go missing for two reasons: a `musicKit://` address MusicKit hands out for radio,
/// which nothing can load, and an Apple address that has since been taken down. Neither heals
/// on its own, because the backfill only fills rows that have no cover at all.
struct ArtworkRepairSection: View {
    @Environment(AppModel.self) private var model
    @State private var isRepairing = false
    @State private var report: ArtworkRepairReport?

    private var isAvailable: Bool {
        !model.isShowingSampleData && model.capture != nil
    }

    var body: some View {
        Section {
            #if os(macOS)
            SettingsDetailRow(title: Text("Repair Artwork"), detail: detail) {
                if isRepairing {
                    // Where the button was, at a fixed width, so the row doesn't reflow.
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 70)
                } else {
                    Button("Repair", action: repair)
                        .disabled(!isAvailable)
                }
            }
            #else
            Button(action: repair) {
                // An `HStack` rather than `LabeledContent`, which would style the row as a
                // read-out and lose the button's tint. The spinner sits where a disclosure
                // would, so the title doesn't move when it appears.
                HStack {
                    Text(isRepairing ? "Repairing Artwork…" : "Repair Artwork")
                    Spacer()
                    if isRepairing {
                        ProgressView()
                    }
                }
            }
            .disabled(isRepairing || !isAvailable)
            #endif
        } header: {
            Text("Artwork")
        } footer: {
            #if os(iOS)
            detail
            #endif
        }
    }

    /// What the button does, then what it found once it has run.
    private var detail: Text {
        if model.isShowingSampleData {
            return Text("Not available while Tracks shows sample data.")
        }
        guard let report else {
            return Text("Checks every cover in your history and asks Apple Music again for the ones that no longer load. It can take a minute over a long history.")
        }
        guard !report.foundNothingWrong else {
            return Text("Checked ^[\(report.checked) cover](inflect: true). They all load.")
        }
        return Text("Replaced ^[\(report.restored) cover](inflect: true) of the ^[\(report.cleared) song](inflect: true) that had a broken one.")
    }

    private func repair() {
        // The capture service, not the environment: the Mac's Settings window is its own
        // scene and only ever gets the model.
        guard let capture = model.capture else { return }
        isRepairing = true
        report = nil
        Task {
            let result = await capture.repairArtwork()
            // Artists Apple Music had no picture for are back in the queue now.
            model.library.refreshArtistArtwork()
            report = result
            isRepairing = false
        }
    }
}
