import Foundation

/// The words for bringing the Last.fm history into Tracks, on the Last.fm page and pane.
///
/// Pure, so tests pin every state's line and button, and the iPhone footer and the Mac row's
/// detail can't drift apart.
public enum LastFMHistoryWords {

    /// Where importing stands, as Settings shows it.
    public enum State: Sendable, Equatable {
        /// Never imported for this account.
        case notImported
        /// Reading now.
        case importing(read: Int, total: Int?, added: Int)
        /// A run stopped part way, by the person or a failure, with what it had added in all.
        case stopped(added: Int)
        /// Everything up to the last sync is in.
        case upToDate(lastSynced: Date, added: Int)
        case failed(String)

        public init(progress: LastFMHistory.Progress?, running: LastFMHistoryImporter.Report?, failure: String?) {
            if let running {
                self = .importing(read: running.read, total: running.total, added: running.imported)
            } else if let failure {
                self = .failed(failure)
            } else if let progress, progress.isUnfinished {
                self = .stopped(added: progress.imported)
            } else if let progress, let finished = progress.lastFinished {
                self = .upToDate(lastSynced: finished, added: progress.imported)
            } else {
                self = .notImported
            }
        }

        public var isImporting: Bool {
            if case .importing = self { return true }
            return false
        }
    }

    /// The Mac row's title, under a History header.
    public static let title = String(localized: "Import Scrobbles")

    /// The iPhone row, which is the button itself. It stops a run that's going, and
    /// otherwise starts one.
    public static func action(_ state: State) -> String {
        switch state {
        case .notImported: String(localized: "Import Your Scrobbles")
        case .importing: String(localized: "Stop Importing")
        case .stopped: String(localized: "Continue Importing")
        case .upToDate: String(localized: "Sync Now")
        case .failed: String(localized: "Try Again")
        }
    }

    /// The Mac row's button, beside ``title``.
    public static func button(_ state: State) -> String {
        switch state {
        case .notImported: String(localized: "Import")
        case .importing: String(localized: "Stop")
        case .stopped: String(localized: "Continue")
        case .upToDate: String(localized: "Sync Now")
        case .failed: String(localized: "Try Again")
        }
    }

    /// The line under the title on the Mac, and the footer on iPhone.
    public static func detail(_ state: State) -> String {
        switch state {
        case .notImported:
            String(localized: "Add the songs you’ve scrobbled to your history in Tracks, dated when you played them. Songs Tracks already has are skipped, and nothing is sent back to Last.fm.")
        case .importing(let read, let total?, let added) where total > 0:
            String(localized: "Importing… read \(read.formatted()) of \(total.formatted()) scrobbles · \(added.formatted()) new")
        case .importing(let read, _, let added):
            read == 0
                ? String(localized: "Importing…")
                : String(localized: "Importing… read \(read.formatted()) scrobbles · \(added.formatted()) new")
        case .stopped(let added):
            String(localized: "Stopped part way · \(plays(added)) added so far. Continue picks up where it left off.")
        case .upToDate(let lastSynced, let added):
            String(localized: "Synced \(lastSynced.formatted(.relative(presentation: .named, unitsStyle: .wide))) · \(plays(added)) added from Last.fm. Sync again to add what you’ve scrobbled since, from any app.")
        case .failed(let message):
            String(localized: "Couldn’t import. \(message)")
        }
    }

    /// The question asked right after connecting.
    public static let offerTitle = String(localized: "Import your Last.fm history?")

    public static let offerMessage = String(localized: "Tracks can add the songs you’ve scrobbled to your history, dated when you played them. Songs Tracks already has are skipped, and nothing is sent back to Last.fm. You can do this later from this page.")

    /// "1 play", "12,345 plays".
    static func plays(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 play")
            : String(localized: "\(count.formatted()) plays")
    }
}
