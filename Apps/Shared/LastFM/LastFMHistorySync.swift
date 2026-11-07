import Foundation
import Observation
import TracksCore

/// Brings the connected account's Last.fm history into Tracks, and says how that's going.
///
/// Owned by the app model rather than Settings, so a long first import keeps going when
/// Settings closes.
@MainActor
@Observable
final class LastFMHistorySync {
    enum Phase: Equatable {
        case idle
        case importing(LastFMHistoryImporter.Report)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// What's been imported so far, for the account that's connected now.
    private(set) var progress: LastFMHistory.Progress?

    private let store: TracksStore
    private let settings: CaptureSettings
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Which run is current, so a stopped run still unwinding can't write over a new one.
    @ObservationIgnored private var runID = UUID()

    init(store: TracksStore, settings: CaptureSettings = CaptureSettings()) {
        self.store = store
        self.settings = settings
        readProgress()
    }

    var isImporting: Bool {
        if case .importing = phase { return true }
        return false
    }

    /// Whether this account's history has been imported at least once.
    var hasImported: Bool { progress?.lastFinished != nil }

    /// Where importing stands, in the terms Settings words it in.
    var state: LastFMHistoryWords.State {
        switch phase {
        case .idle: LastFMHistoryWords.State(progress: progress, running: nil, failure: nil)
        case .importing(let report): LastFMHistoryWords.State(progress: progress, running: report, failure: nil)
        case .failed(let message): LastFMHistoryWords.State(progress: progress, running: nil, failure: message)
        }
    }

    /// Starts a run, or stops the one that's going.
    func startOrStop() {
        isImporting ? stop() : start()
    }

    /// Reads everything Tracks doesn't have yet: the whole history the first time, then only
    /// what's new. Does nothing while a run is going.
    func start() {
        guard task == nil else { return }
        guard let session = LastFMSessionStore.current else {
            phase = .failed(ScrobbleService.describe(LastFMError.notConnected))
            return
        }
        guard let client = LastFMClient.configured() else {
            phase = .failed(ScrobbleService.describe(LastFMError.notConfigured))
            return
        }
        phase = .importing(LastFMHistoryImporter.Report())
        let importer = LastFMHistoryImporter(client: client, session: session, store: store, settings: settings)
        let id = UUID()
        runID = id
        task = Task {
            var ending = Phase.idle
            do {
                try await importer.run { [weak self] report in
                    guard let self, self.runID == id else { return }
                    self.phase = .importing(report)
                    self.readProgress()
                }
            } catch is CancellationError {
            } catch {
                // Stop cancels a request in flight, which URLSession reports as its own error.
                let wasStopped = Task.isCancelled || (error as? URLError)?.code == .cancelled
                if !wasStopped { ending = .failed(ScrobbleService.describe(error)) }
            }
            guard runID == id else { return }
            phase = ending
            readProgress()
            task = nil
        }
    }

    /// Stops a run at once, so a new one can start straight away. What it has read so far
    /// stays, and the next run picks up from there.
    func stop() {
        task?.cancel()
        task = nil
        runID = UUID()
        phase = .idle
        readProgress()
    }

    /// Picks up a change of account.
    func readProgress() {
        progress = LastFMSessionStore.current.map { settings.lastFMHistory(for: $0.username) }
    }
}
