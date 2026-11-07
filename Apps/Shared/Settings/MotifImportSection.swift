import SwiftUI
import TracksCore

/// Brings listening history over from Motif, the app Tracks replaces. Only on a device that
/// has Motif. It runs by itself the first time; this shows what happened and runs it again.
struct MotifImportSection: View {
    @Environment(AppModel.self) private var model

    private var isRunning: Bool { model.motifImport == .running }

    private var isAvailable: Bool {
        !model.isShowingSampleData && model.store != nil
    }

    private var title: LocalizedStringKey {
        if isRunning { return "Bringing Over History…" }
        return MotifImport.finishedAt == nil ? "Bring Over Motif History" : "Bring Over Again"
    }

    var body: some View {
        Section {
            #if os(macOS)
            SettingsDetailRow(title: Text("Motif History"), detail: detail) {
                if isRunning {
                    // Where the button was, at a fixed width, so the row doesn't reflow.
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 90)
                } else {
                    Button(MotifImport.finishedAt == nil ? "Bring Over" : "Again", action: run)
                        .disabled(!isAvailable)
                }
            }
            #else
            Button(action: run) {
                HStack {
                    Text(title)
                    Spacer()
                    if isRunning {
                        ProgressView()
                    }
                }
            }
            .disabled(isRunning || !isAvailable)
            #endif
        } header: {
            Text("Motif")
        } footer: {
            #if os(iOS)
            detail
            #endif
        }
    }

    /// What happened, newest first: this run, the last run here, or another device's.
    private var detail: Text {
        if model.isShowingSampleData {
            return Text("Not available while Tracks shows sample data.")
        }
        switch model.motifImport {
        case .running:
            return Text("Copying your plays from Motif. Motif itself isn't changed.")
        case .failed(let reason):
            return Text(reason)
        case .finished(let outcome) where outcome.plays == 0:
            return Text("Everything from Motif is already here.")
        case .finished(let outcome):
            return Text("Brought over ^[\(outcome.plays) play](inflect: true) from Motif. Motif itself isn't changed.")
        case .idle:
            break
        }
        if let date = MotifImport.finishedAt {
            return Text("Brought over ^[\(MotifImport.importedPlays) play](inflect: true) from Motif \(date.formatted(.relative(presentation: .named))). Run it again to pick up anything Motif kept since.")
        }
        if let device = MotifImport.importedOnOtherDevice {
            return Text("Your Motif history came over on \(device) and reaches this device through iCloud. Bring it over here too if anything's missing.")
        }
        return Text("Copies everything Motif kept on this device into Tracks, with its stations, sessions and settings. Motif itself isn't changed.")
    }

    private func run() {
        Task { await model.importFromMotif() }
    }
}
