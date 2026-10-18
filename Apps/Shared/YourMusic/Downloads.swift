import Foundation
import Observation
import OSLog
import TracksCore

/// Songs downloaded from your servers to play without a connection: the original files, FLAC
/// and all, or a smaller copy the server makes, as Download Quality asks. Downloads carry on
/// in the background, and with the app closed.
@MainActor
@Observable
final class Downloads {
    /// A song kept on this iPhone.
    struct Item: Codable, Sendable {
        let track: LocalTrack
        /// Its name in the downloads folder.
        let fileName: String
        let bytes: Int64
        let downloadedAt: Date
        /// The bit rate the download asked the server for. Nil asked for the original file, as
        /// every download did before Download Quality.
        var requestedBitRate: Int?
        /// What the file turned out to be, read once it landed. Nil for downloads from before
        /// that was read, which are the original files.
        var format: AudioFormat?

        /// The song as it is on this iPhone: its format the file's, where that's known.
        var keptTrack: LocalTrack {
            guard let format else { return track }
            var kept = track
            kept.format = format
            return kept
        }

        /// A smaller copy rather than the original.
        var isSmallerCopy: Bool {
            guard let format else { return false }
            return AudioQuality(LocalPlayback(route: .downloaded(requestedBitRate: requestedBitRate), original: track.format, actual: format))
                .map { if case .converted = $0.reason { true } else { false } } ?? false
        }
    }

    private(set) var items: [String: Item] = [:]
    /// Songs on their way, by track id, from 0 to 1.
    private(set) var progress: [String: Double] = [:] {
        didSet {
            let ids = Set(progress.keys)
            if ids != downloading { downloading = ids }
        }
    }
    /// The songs in ``progress``, changing only when one starts or ends, so what needs only
    /// to know a song is on its way isn't redrawn at every step of it.
    private(set) var downloading: Set<String> = []
    /// Songs on their way whose first bytes have come, so they aren't waiting to start.
    private(set) var started: Set<String> = []
    /// Songs on their way from a server that didn't say how big they are, so how far along
    /// they are can't be told.
    private(set) var sizeUnknown: Set<String> = []
    /// Called with each song once it's downloaded.
    @ObservationIgnored var onDownloaded: ((LocalTrack) -> Void)?
    /// Songs that couldn't be downloaded, by track id, with why.
    private(set) var failures: [String: String] = [:]

    /// Whether downloads may use cellular data. On unless turned off; off, they wait for Wi-Fi.
    static let cellularKey = "yourMusicDownloadsOverCellular"

    static var allowsCellular: Bool {
        UserDefaults.standard.object(forKey: cellularKey) as? Bool ?? true
    }

    @ObservationIgnored private let servers: MusicServers
    /// A download under way: the song, and the attempt, so a late word from an attempt that
    /// was stopped or replaced is ignored.
    struct Pending: Codable, Sendable {
        let track: LocalTrack
        let attempt: String
        /// The bit rate asked for, or nil for the original file.
        var requestedBitRate: Int?
    }

    @ObservationIgnored private var pending: [String: Pending] = [:]
    /// Attempts stopped on purpose, whose cancellation isn't a failure.
    @ObservationIgnored private var stoppedAttempts: Set<String> = []
    @ObservationIgnored private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.httpMaximumConnectionsPerHost = 3
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }()
    @ObservationIgnored private let delegate = DownloadDelegate()
    /// iOS hands this over when it wakes Tracks to finish downloads, and wants it called when
    /// they've been dealt with.
    @ObservationIgnored var backgroundCompletion: (() -> Void)?

    static let sessionIdentifier = "com.luke.tracks.downloads"
    private static var recordURL: URL { LibraryFolders.index.appending(path: "downloads.json") }
    private static var pendingURL: URL { LibraryFolders.index.appending(path: "downloads-pending.json") }

    init(servers: MusicServers) {
        self.servers = servers
        items = Self.load(Self.recordURL) ?? [:]
        pending = Self.load(Self.pendingURL) ?? [:]
        // Files deleted behind Tracks’ back aren't downloaded any more.
        items = items.filter { FileManager.default.fileExists(atPath: Self.fileURL($0.value.fileName).path(percentEncoded: false)) }
        delegate.owner = self
        // Picks up downloads still running from before.
        _ = session
        Task { await restoreProgress() }
    }

    // MARK: - Asking

    func isDownloaded(_ trackID: String) -> Bool { items[trackID] != nil }

    func isDownloading(_ trackID: String) -> Bool { downloading.contains(trackID) }

    /// Where a downloaded song is on this iPhone.
    func fileURL(for trackID: String) -> URL? {
        items[trackID].map { Self.fileURL($0.fileName) }
    }

    /// How a downloaded song reaches the player, for the quality badge.
    func playback(for trackID: String) -> LocalPlayback? {
        items[trackID].map {
            LocalPlayback(route: .downloaded(requestedBitRate: $0.requestedBitRate), original: $0.track.format, actual: $0.format)
        }
    }

    var totalBytes: Int64 { items.values.map(\.bytes).reduce(0, +) }

    /// Every downloaded song, as your own.
    var tracks: [LocalTrack] { items.values.map(\.track) }

    // MARK: - Downloading

    /// Starts downloading songs from their servers, the ones not already here, at the Download
    /// Quality set now: the original file, or a smaller copy the server makes as it sends it.
    func download(_ tracks: [LocalTrack]) {
        onAsked?(tracks)
        start(tracks)
    }

    /// Called with the songs each ``download(_:)`` asks for, before they start: Your Music
    /// hears which ones are wanted to keep, as against the ones Tracks Radio gets ready.
    @ObservationIgnored var onAsked: (([LocalTrack]) -> Void)?

    /// Downloads songs, as asked already: again after a change of setting, or a retry.
    private func start(_ tracks: [LocalTrack]) {
        let allowsCellular = Self.allowsCellular
        let bitRate = StreamQuality.download.maxBitRate
        for track in tracks {
            guard case .server(let serverID, let songID) = track.origin,
                  items[track.id] == nil, progress[track.id] == nil,
                  let client = servers.client(for: serverID)
            else { continue }
            let url = bitRate.map { client.streamURL(songID: songID, maxBitRate: $0) } ?? client.downloadURL(songID: songID)
            var request = URLRequest(url: url)
            request.allowsCellularAccess = allowsCellular
            request.allowsExpensiveNetworkAccess = allowsCellular
            let attempt = UUID().uuidString
            let task = session.downloadTask(with: request)
            task.taskDescription = Self.describe(trackID: track.id, attempt: attempt)
            pending[track.id] = Pending(track: track, attempt: attempt, requestedBitRate: bitRate)
            progress[track.id] = 0
            started.remove(track.id)
            sizeUnknown.remove(track.id)
            failures[track.id] = nil
            task.resume()
        }
        Self.save(pending, to: Self.pendingURL)
    }

    /// Whether a download is queued and hasn't started: waiting for Wi-Fi, with cellular off.
    func isWaitingForWiFi(_ trackID: String, onCellular: Bool) -> Bool {
        onCellular && !Self.allowsCellular && downloading.contains(trackID) && !started.contains(trackID)
    }

    /// Downloading over cellular was turned on or off: the downloads that haven't started are
    /// asked for again under the new rule, so ones waiting for Wi-Fi start at once, or ones
    /// about to start on cellular wait.
    func cellularSettingChanged() {
        let notStarted = pending.filter { progress[$0.key] != nil && !started.contains($0.key) }
        guard !notStarted.isEmpty else { return }
        cancel(Set(notStarted.keys))
        start(notStarted.values.map(\.track))
    }

    /// Stops a download under way.
    func cancel(_ trackIDs: Set<String>) {
        // Only these attempts: a download of the same song started again right after is left alone.
        let attempts = Set(trackIDs.compactMap { pending[$0]?.attempt })
        stoppedAttempts.formUnion(attempts)
        session.getAllTasks { tasks in
            for task in tasks {
                guard let (_, attempt) = Self.parse(task.taskDescription), attempts.contains(attempt) else { continue }
                task.cancel()
            }
        }
        for id in trackIDs {
            progress[id] = nil
            started.remove(id)
            sizeUnknown.remove(id)
            pending[id] = nil
        }
        Self.save(pending, to: Self.pendingURL)
    }

    /// Deletes downloaded songs from this iPhone. They stay on the server.
    func remove(_ trackIDs: Set<String>) {
        for id in trackIDs {
            if let item = items.removeValue(forKey: id) {
                try? FileManager.default.removeItem(at: Self.fileURL(item.fileName))
            }
            failures[id] = nil
        }
        Self.save(items, to: Self.recordURL)
    }

    func removeAll() {
        cancel(Set(progress.keys))
        remove(Set(items.keys))
        failures = [:]
    }

    func retryFailed() {
        let tracks = failures.keys.compactMap { id in pending[id]?.track ?? catalogTrack(id) }
        failures = [:]
        start(tracks)
    }

    // MARK: - From the session

    /// - Parameter fraction: how far along it is, or nil when the server didn't say its size.
    fileprivate func didWrite(_ trackID: String, attempt: String, fraction: Double?) {
        guard pending[trackID]?.attempt == attempt else { return }
        if !started.contains(trackID) { started.insert(trackID) }
        guard let fraction else {
            if !sizeUnknown.contains(trackID) { sizeUnknown.insert(trackID) }
            return
        }
        // Every row showing a download redraws on each write: whole percents are plenty, and
        // the session reports every chunk.
        if let shown = progress[trackID], fraction < 1, fraction - shown < 0.01 { return }
        progress[trackID] = fraction
    }

    fileprivate func didFinish(_ trackID: String, attempt: String, fileName: String?, bytes: Int64, outcome: Outcome) {
        let current = pending[trackID]
        // Stopped on purpose, or a newer attempt at the same song is under way: this one's
        // word is stale, and the file it landed isn't wanted.
        let wasStopped = stoppedAttempts.remove(attempt) != nil
        if wasStopped || (current.map { $0.attempt != attempt } ?? false) {
            Self.discard(fileName)
            return
        }
        progress[trackID] = nil
        started.remove(trackID)
        sizeUnknown.remove(trackID)
        pending[trackID] = nil
        Self.save(pending, to: Self.pendingURL)
        switch outcome {
        case .finished:
            // After a relaunch the attempt may be gone from memory; the library still knows the song.
            guard let fileName else { return }
            guard let track = current?.track ?? catalogTrack(trackID) else {
                Self.discard(fileName)
                return
            }
            let replaced = items[trackID]?.fileName
            items[trackID] = Item(track: track, fileName: fileName, bytes: bytes, downloadedAt: .now, requestedBitRate: current?.requestedBitRate)
            if replaced != fileName { Self.discard(replaced) }
            failures[trackID] = nil
            Self.save(items, to: Self.recordURL)
            onDownloaded?(track)
            readFormat(of: trackID, fileName: fileName)
        case .failed(let reason):
            failures[trackID] = reason
        }
    }

    enum Outcome: Sendable {
        case finished
        case failed(String)
    }

    /// Reads what a download turned out to be, so it's shown truthfully: the original, or the
    /// smaller copy the server made, or the original sent when a copy was asked for.
    private func readFormat(of trackID: String, fileName: String) {
        let url = Self.fileURL(fileName)
        Task {
            guard let found = await AudioQualityProbe.format(of: url),
                  let item = items[trackID], item.fileName == fileName
            else { return }
            items[trackID]?.format = AudioFormat.settled(actual: found, original: item.track.format)
            Self.save(items, to: Self.recordURL)
        }
    }

    private func catalogTrack(_ id: String) -> LocalTrack? {
        for tracks in servers.catalogs.values {
            if let track = tracks.first(where: { $0.id == id }) { return track }
        }
        return nil
    }

    fileprivate func didFinishBackgroundEvents() {
        backgroundCompletion?()
        backgroundCompletion = nil
    }

    /// Shows the progress of downloads still running from before. Ones that finished while
    /// Tracks wasn't running are reported by the session as it reconnects, so they're left be.
    private func restoreProgress() async {
        let tasks = await session.allTasks
        for task in tasks {
            guard let (id, attempt) = Self.parse(task.taskDescription), pending[id]?.attempt == attempt else { continue }
            let expected = task.countOfBytesExpectedToReceive
            let received = task.countOfBytesReceived
            progress[id] = expected > 0 ? Double(received) / Double(expected) : 0
            if received > 0 { started.insert(id) }
            if received > 0, expected <= 0 { sizeUnknown.insert(id) }
        }
    }

    nonisolated static func describe(trackID: String, attempt: String) -> String {
        trackID + "\u{1F}" + attempt
    }

    nonisolated static func parse(_ description: String?) -> (trackID: String, attempt: String)? {
        guard let parts = description?.split(separator: "\u{1F}", maxSplits: 1), parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    // MARK: - Files

    nonisolated static func fileURL(_ name: String) -> URL {
        LibraryFolders.downloads.appending(path: name)
    }

    private static func discard(_ name: String?) {
        guard let name else { return }
        try? FileManager.default.removeItem(at: fileURL(name))
    }

    /// Why a download failed, in a sentence that says what to do. The system's own words go
    /// to the log, since they name sockets and file paths.
    nonisolated static func failureReason(for error: any Error) -> String {
        if let code = (error as? URLError)?.code {
            switch code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return String(localized: "You’re offline. Try again once you’re connected.")
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .timedOut:
                return String(localized: "Your server didn’t answer. Check that it’s running, then try again.")
            default:
                break
            }
        }
        if isOutOfSpace(error) {
            return String(localized: "There isn’t enough space for it. Free up some space, then try again.")
        }
        return String(localized: "Couldn’t download this song. Try again.")
    }

    private nonisolated static func isOutOfSpace(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteOutOfSpaceError { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOSPC) { return true }
        return (error.userInfo[NSUnderlyingErrorKey] as? NSError).map(isOutOfSpace) ?? false
    }

    /// A safe file name for a track id, which holds colons and a server's own characters. Each
    /// attempt lands under its own, so a stale one can be deleted without touching a newer one.
    nonisolated static func fileName(for trackID: String, attempt: String, suffix: String) -> String {
        let safe = trackID.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        return String(safe) + "-" + attempt.prefix(8) + "." + (suffix.isEmpty ? "audio" : suffix)
    }

    private static func load<Value: Decodable>(_ url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    private static func save<Value: Encodable>(_ value: Value, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// The session's delegate. The finished file has to be moved before its callback returns, so
/// that happens here, off the main actor; everything else is handed to ``Downloads``.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    @MainActor weak var owner: Downloads?
    private nonisolated static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Tracks", category: "Downloads")

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let (id, attempt) = Downloads.parse(downloadTask.taskDescription) else { return }
        let fraction = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil
        Task { @MainActor in self.owner?.didWrite(id, attempt: attempt, fraction: fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let (id, attempt) = Downloads.parse(downloadTask.taskDescription) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else {
            let reason = String(localized: "The server wouldn't send it (\(status)).")
            Task { @MainActor in self.owner?.didFinish(id, attempt: attempt, fileName: nil, bytes: 0, outcome: .failed(reason)) }
            return
        }
        let manager = FileManager.default
        let size = (try? manager.attributesOfItem(atPath: location.path(percentEncoded: false))[.size] as? Int64) ?? 0
        let head = (try? FileHandle(forReadingFrom: location)).flatMap { handle in
            defer { try? handle.close() }
            return try? handle.read(upToCount: DownloadedAudio.headLength)
        } ?? Data()
        guard DownloadedAudio.isAudio(mimeType: downloadTask.response?.mimeType, head: head, size: size) else {
            Self.log.error("A download wasn't audio: \(downloadTask.response?.mimeType ?? "no type", privacy: .public), \(size) bytes")
            let reason = String(localized: "Your server sent an error instead of the song. Try again later.")
            Task { @MainActor in self.owner?.didFinish(id, attempt: attempt, fileName: nil, bytes: 0, outcome: .failed(reason)) }
            return
        }
        let suffix = Self.suffix(for: downloadTask.response)
        let name = Downloads.fileName(for: id, attempt: attempt, suffix: suffix)
        let destination = Downloads.fileURL(name)
        try? manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? manager.removeItem(at: destination)
        do {
            try manager.moveItem(at: location, to: destination)
            let bytes = (try? manager.attributesOfItem(atPath: destination.path(percentEncoded: false))[.size] as? Int64) ?? 0
            Task { @MainActor in self.owner?.didFinish(id, attempt: attempt, fileName: name, bytes: bytes, outcome: .finished) }
        } catch {
            Self.log.error("Couldn't keep a download: \(error, privacy: .public)")
            let reason = Downloads.failureReason(for: error)
            Task { @MainActor in self.owner?.didFinish(id, attempt: attempt, fileName: nil, bytes: 0, outcome: .failed(reason)) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error, let (id, attempt) = Downloads.parse(task.taskDescription) else { return }
        // A cancel Tracks didn't ask for (the app was quit, say) is a failure, to try again; one it
        // did ask for is ignored by the owner, which knows the attempt was stopped.
        Self.log.error("A download failed: \(error, privacy: .public)")
        let reason = (error as? URLError)?.code == .cancelled
            ? String(localized: "Stopped before it finished.")
            : Downloads.failureReason(for: error)
        Task { @MainActor in
            self.owner?.didFinish(id, attempt: attempt, fileName: nil, bytes: 0, outcome: .failed(reason))
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in self.owner?.didFinishBackgroundEvents() }
    }

    /// The file's own extension, from its type, or else the server's name for it. The type
    /// comes first: a smaller copy is an MP3 whatever the original was called, and a file
    /// with the wrong extension won't play.
    private static func suffix(for response: URLResponse?) -> String {
        switch response?.mimeType {
        case "audio/flac", "audio/x-flac": return "flac"
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/mp4", "audio/aac", "audio/x-m4a": return "m4a"
        case "audio/wav", "audio/x-wav": return "wav"
        default: break
        }
        if let name = response?.suggestedFilename, let ext = name.split(separator: ".").last, ext.count <= 5, name.contains(".") {
            return ext.lowercased()
        }
        return "audio"
    }
}
