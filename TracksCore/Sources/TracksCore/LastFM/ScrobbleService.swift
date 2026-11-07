import Foundation
import SwiftData

/// Sends captures to Last.fm.
///
/// Like the playlist queue, failures are stored on the row, so a device that was offline
/// catches up when it's back.
@MainActor
public final class ScrobbleService {
    private let store: TracksStore
    private let settings: CaptureSettings
    private let makeClient: @Sendable () -> LastFMClient?
    /// The connected account. The Keychain in the app; injected in tests, which mustn't
    /// touch the developer's own session.
    private let currentSession: @Sendable () -> LastFMSession?

    public private(set) var lastError: String?

    /// The drain in progress, which later callers wait on rather than starting their own.
    ///
    /// The queue is drained from launch, after each capture and from the housekeeping timer,
    /// and each of those can arrive while another drain is waiting on Last.fm with the same
    /// rows. Two drains at once sent every scrobble twice.
    private var running: Task<Int, Never>?
    /// Set when someone asked for a drain while one was running, so rows that turned up
    /// after the running drain last looked get another pass.
    private var wantsAnotherPass = false

    /// Leaves Last.fm alone for a while after a failure that isn't the rows' fault.
    private(set) var backoff = RetryBackoff()
    /// The clock, replaceable so tests can step past the backoff.
    var now: () -> Date = { .now }

    public init(
        store: TracksStore,
        settings: CaptureSettings = CaptureSettings(),
        makeClient: @escaping @Sendable () -> LastFMClient? = { LastFMClient.configured() },
        currentSession: @escaping @Sendable () -> LastFMSession? = { LastFMSessionStore.current }
    ) {
        self.store = store
        self.settings = settings
        self.makeClient = makeClient
        self.currentSession = currentSession
    }

    public var isConnected: Bool { currentSession() != nil }

    /// Sends everything owed, oldest first, in batches.
    ///
    /// Cheap to call any time; does nothing if there's nothing owed, no account, scrobbling
    /// is off, or Last.fm failed recently. If a drain is already running this waits for it,
    /// and it takes one more look at the queue before finishing.
    ///
    /// - Returns: how many scrobbles Last.fm accepted.
    @discardableResult
    public func drain() async -> Int {
        if let running {
            wantsAnotherPass = true
            return await running.value
        }
        let task = Task {
            var sent = 0
            repeat {
                wantsAnotherPass = false
                sent += await drainOnce()
            } while wantsAnotherPass
            // Cleared here rather than by the caller, with nothing in between that can
            // suspend, so a caller can't join a drain that has already finished looking.
            running = nil
            return sent
        }
        running = task
        return await task.value
    }

    private func drainOnce() async -> Int {
        guard settings.scrobblesToLastFM else { return 0 }
        guard let session = currentSession(), let client = makeClient() else { return 0 }
        guard backoff.allows(at: now()) else { return 0 }

        var sent = 0
        // Imports already looked for on Last.fm and not found there.
        var checked: Set<PersistentIdentifier> = []
        // Up to fifty scrobbles per request.
        while true {
            // Saved first, so every row has the identity it will keep.
            try? store.context.save()
            let descriptor = TracksStore.pendingScrobbles(
                includingImported: settings.scrobblesImported,
                limit: LastFMClient.batchLimit
            )
            guard let owed = try? store.context.fetch(descriptor), !owed.isEmpty else { break }

            // Apple's recently-played list covers the whole account, so an import can be a
            // play another device already scrobbled. Last.fm's own history is the only thing
            // that knows, whether or not that device's rows have synced here yet.
            let imports = owed.filter { $0.kind == .imported && !checked.contains($0.persistentModelID) }
            if !imports.isEmpty {
                let candidates = imports.map {
                    ImportedPlay(
                        id: $0.persistentModelID,
                        key: HistoryImport.key(title: $0.title, artistName: $0.artistName),
                        foundAt: $0.capturedAt
                    )
                }
                let window = settings.dedupePolicy.importWindow
                let earliest = candidates.map(\.foundAt).min() ?? now()
                let history: [ScrobbledTrack]
                do {
                    history = try await client.recentTracks(
                        session: session,
                        after: earliest.addingTimeInterval(-window)
                    ).scrobbles
                } catch {
                    // Sending without knowing could scrobble the play twice, so wait.
                    Log.lastFM.error("Checking Last.fm history failed: \(String(describing: error), privacy: .public)")
                    lastError = Self.describe(error)
                    backoff.recordFailure(at: now())
                    return sent
                }
                let found = Self.alreadyScrobbled(candidates, history: history, window: window)
                checked.formUnion(candidates.map(\.id).filter { !found.contains($0) })
                if !found.isEmpty {
                    let stamp = now()
                    for capture in store.existingCaptures(Array(found)).values {
                        capture.scrobbledAt = stamp
                        capture.lastScrobbleError = nil
                    }
                    guard (try? store.context.save()) != nil else { return sent }
                    // Fetched again: the batch has room for rows that were behind these.
                    continue
                }
            }

            // Only identities cross the request: the rows may be merged away meanwhile.
            let ids = owed.map(\.persistentModelID)
            let scrobbles = owed.map {
                Scrobble(
                    artist: $0.artistName,
                    track: $0.title,
                    album: $0.albumTitle,
                    playedAt: $0.capturedAt
                )
            }

            let outcomes: [ScrobbleOutcome]
            do {
                outcomes = try await client.submit(scrobbles, session: session)
            } catch {
                Log.lastFM.error("Scrobbling failed: \(String(describing: error), privacy: .public)")
                let message = Self.describe(error)
                lastError = message
                if Self.isTheScrobblesFault(error) {
                    for capture in store.existingCaptures(ids).values {
                        capture.scrobbleAttempts += 1
                        capture.lastScrobbleError = message
                    }
                    try? store.context.save()
                } else {
                    // Offline, Last.fm down or rate limiting, or an account problem. Nothing
                    // to do with these rows, so they keep their attempts and wait.
                    backoff.recordFailure(at: now())
                }
                // Stop here either way: the next batch would fail the same way.
                return sent
            }

            let rows = store.existingCaptures(ids)
            let stamp = now()
            var heldBack: String?
            for (id, outcome) in zip(ids, outcomes) {
                // Accepted or not, a row merged away while the request was out has nothing
                // left to record it on.
                if outcome.isAccepted { sent += 1 }
                guard let capture = rows[id] else { continue }
                switch outcome {
                case .accepted:
                    capture.scrobbledAt = stamp
                    capture.lastScrobbleError = nil
                case .ignored(let code, let message) where outcome.isRetryable:
                    // Left owed, untouched, for when the limit or the clock allows it.
                    heldBack = Self.describeIgnored(code: code, message: message)
                case .ignored(let code, let message):
                    // Last.fm will never take this one. Give up on it now, with the reason,
                    // which is what the history shows next to it. Marking it scrobbled would
                    // claim a play Last.fm doesn't have.
                    capture.scrobbleAttempts = max(capture.scrobbleAttempts, TracksStore.maxScrobbleAttempts)
                    capture.lastScrobbleError = Self.describeIgnored(code: code, message: message)
                }
            }
            // A save that fails would leave these rows owed, and the loop would send them again.
            guard (try? store.context.save()) != nil else { return sent }

            if let heldBack {
                // Not reset first, so a daily limit that is still in force keeps lengthening
                // the wait instead of being asked about again every thirty seconds.
                lastError = heldBack
                backoff.recordFailure(at: now())
                return sent
            }
            backoff.reset()
            lastError = nil
            if owed.count < LastFMClient.batchLimit { break }
        }
        return sent
    }

    /// An import waiting to be sent, as the Last.fm history check sees it.
    struct ImportedPlay: Sendable {
        let id: PersistentIdentifier
        let key: String
        let foundAt: Date
    }

    /// The imports Last.fm already has: the same song scrobbled within `window` before the
    /// import found it. Each scrobble accounts for one import at most.
    static func alreadyScrobbled(
        _ imports: [ImportedPlay],
        history: [ScrobbledTrack],
        window: TimeInterval
    ) -> Set<PersistentIdentifier> {
        var scrobbled: [String: [Date]] = [:]
        for track in history {
            scrobbled[HistoryImport.key(title: track.title, artistName: track.artistName), default: []]
                .append(track.playedAt)
        }
        var found: Set<PersistentIdentifier> = []
        for play in imports {
            guard let index = scrobbled[play.key]?.firstIndex(where: {
                $0 <= play.foundAt && play.foundAt.timeIntervalSince($0) <= window
            }) else { continue }
            scrobbled[play.key]?.remove(at: index)
            found.insert(play.id)
        }
        return found
    }

    /// Whether a failed request says something about the scrobbles in it, so each is charged
    /// an attempt and eventually given up on.
    ///
    /// Only an error Last.fm itself sent back about the request counts. Everything else (no
    /// network, a timeout, Last.fm down or rate limiting, the account, a proxy's bare 4xx or a
    /// page that isn't Last.fm's) would fail any request, and charging the rows would throw
    /// away listening because of an outage.
    static func isTheScrobblesFault(_ error: any Error) -> Bool {
        guard let error = error as? LastFMError, case .service = error else { return false }
        return !error.isRetryable && !error.concernsAccount
    }

    /// Tells Last.fm what's playing. Not queued, since it expires on its own.
    public func updateNowPlaying(title: String, artistName: String, albumTitle: String?) async {
        guard settings.scrobblesToLastFM,
              let session = currentSession(),
              let client = makeClient()
        else { return }
        try? await client.updateNowPlaying(
            Scrobble(artist: artistName, track: title, album: albumTitle, playedAt: .now),
            session: session
        )
    }

    /// What went wrong talking to Last.fm, in words: what happened and what to do. Last.fm's
    /// own codes and messages mean nothing to the person reading, so they only go to the log.
    /// Public so the connect flow reports failures in the same words.
    public nonisolated static func describe(_ error: any Error) -> String {
        if let error = error as? URLError {
            return switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                String(localized: "You’re offline. Connect to the internet and try again.")
            case .timedOut, .cannotConnectToHost, .cannotFindHost:
                String(localized: "Last.fm isn’t responding. Try again later.")
            default:
                String(localized: "Couldn’t reach Last.fm. Try again.")
            }
        }
        guard let error = error as? LastFMError else {
            return String(localized: "Something went wrong with Last.fm. Try again.")
        }
        return switch error {
        case .notConfigured:
            String(localized: "Last.fm isn’t set up in this build of Tracks.")
        // 4 authentication failed, 9 invalid session key.
        case .notConnected, .service(code: 4, _), .service(code: 9, _):
            String(localized: "You’re signed out of Last.fm. Connect your account again.")
        // 14 token not authorised, 15 token expired.
        case .notAuthorised, .service(code: 14, _), .service(code: 15, _):
            String(localized: "Last.fm didn’t get your approval. Try connecting again.")
        case _ where error.isRetryable:
            String(localized: "Last.fm isn’t responding. Try again later.")
        case .http, .service, .malformedResponse:
            String(localized: "Something went wrong with Last.fm. Try again.")
        }
    }

    /// Why Last.fm ignored one scrobble from a batch, in words for the history. Last.fm's own
    /// message for it only goes to the log.
    public nonisolated static func describeIgnored(code: Int, message: String) -> String {
        if !message.isEmpty {
            Log.lastFM.notice("Last.fm ignored a scrobble, code \(code): \(message, privacy: .public)")
        }
        return switch code {
        case 1: String(localized: "Last.fm ignored the artist.")
        case 2: String(localized: "Last.fm ignored the track.")
        case 3: String(localized: "Too old for Last.fm, which only takes scrobbles from the last two weeks.")
        case 4: String(localized: "Last.fm thinks this was played in the future. Check the date and time.")
        case 5: String(localized: "Last.fm’s daily scrobble limit was reached.")
        default: String(localized: "Last.fm didn’t take this scrobble.")
        }
    }
}
