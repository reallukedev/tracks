import AVFoundation
import Foundation
import Network
import Observation
import ShazamKit
import Synchronization
import TracksCore
import os

/// Names the song playing nearby with Shazam, and finds it in your history: the radio in a
/// café, a song in a shop. Listens only while it's showing, and only a signature of the sound
/// leaves the device.
@MainActor
@Observable
final class SongIdentifier {
    enum Phase: Equatable {
        case listening
        case found(IdentifiedSong)
        case noMatch
        case microphoneDenied
        case offline
        case failed
    }

    private(set) var phase: Phase = .listening

    /// Longer than Shazam needs for nearly any song, short enough not to listen to a room.
    private static let listeningLimit: Duration = .seconds(20)
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Tracks", category: "Identify")

    /// Listens until Shazam names the song or gives up. Cancelling the task stops listening.
    func listen(history: ListeningHistory, isDemo: Bool) async {
        phase = .listening
        if isDemo {
            // Sample data never reaches Shazam: a sample song from the history is "heard".
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            phase = Self.sample(in: history).map { .found($0) } ?? .noMatch
            return
        }
        guard await Connectivity.isOnline() else {
            phase = .offline
            return
        }
        guard await Self.mayUseMicrophone() else {
            phase = .microphoneDenied
            return
        }
        guard !Task.isCancelled else { return }

        let session = SHManagedSession()
        await session.prepare()
        let limit = Task {
            do {
                try await Task.sleep(for: Self.listeningLimit)
            } catch {
                return false
            }
            session.cancel()
            return true
        }
        let result = await withTaskCancellationHandler {
            await session.result()
        } onCancel: {
            session.cancel()
        }
        limit.cancel()
        let ranOut = await limit.value
        guard !Task.isCancelled else { return }

        switch result {
        case .match(let match):
            guard let item = match.mediaItems.first, let found = IdentifiedSong(item, history: history) else {
                phase = .noMatch
                return
            }
            phase = .found(found)
        case .noMatch:
            phase = .noMatch
        case .error(let error, _):
            Self.log.notice("Shazam couldn't listen: \(error.localizedDescription, privacy: .public)")
            if Self.isConnectionError(error) {
                phase = .offline
            } else if (error as? SHError)?.code == .matchAttemptFailed || ranOut {
                phase = .noMatch
            } else {
                phase = .failed
            }
        @unknown default:
            phase = .failed
        }
    }

    private static func mayUseMicrophone() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: true
        case .undetermined: await AVAudioApplication.requestRecordPermission()
        default: false
        }
    }

    private static func isConnectionError(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSURLErrorDomain { return true }
        return (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.domain == NSURLErrorDomain
    }

    /// A song heard on the radio lately, or else the latest, as if the room had played it.
    private static func sample(in history: ListeningHistory) -> IdentifiedSong? {
        let captures = history.captures
        guard let capture = captures.last(where: { $0.kind == .radio }) ?? captures.last else { return nil }
        return IdentifiedSong(
            title: capture.title,
            artistName: capture.artistName,
            cover: .url(capture.artworkURL, seed: capture.albumTitle ?? capture.title),
            songID: capture.songID,
            history: history
        )
    }
}

/// What Shazam heard, and when you last played it.
struct IdentifiedSong: Equatable {
    let title: String
    let artistName: String
    let cover: CoverArt
    /// Apple Music's id, to play it. Empty when Shazam knows no Apple Music copy.
    let songID: String
    let songIdentity: String
    /// Your latest play of it, if you've played it.
    let lastPlay: CaptureStat?

    init(title: String, artistName: String, cover: CoverArt, songID: String, history: ListeningHistory) {
        self.title = title
        self.artistName = artistName
        self.cover = cover
        self.songID = songID
        let identity = HistoryImport.key(title: title, artistName: artistName)
        songIdentity = identity
        lastPlay = history.captures.last { $0.songIdentity == identity }
    }

    init?(_ item: SHMatchedMediaItem, history: ListeningHistory) {
        guard let title = item.title, !title.isEmpty else { return nil }
        self.init(
            title: title,
            artistName: item.artist ?? "",
            cover: .url(item.artworkURL?.absoluteString, seed: title),
            songID: item.appleMusicID ?? "",
            history: history
        )
    }
}

/// Whether the device has a way to the internet right now, asked once.
private enum Connectivity {
    static func isOnline() async -> Bool {
        let monitor = NWPathMonitor()
        let answered = Mutex(false)
        return await withCheckedContinuation { continuation in
            monitor.pathUpdateHandler = { path in
                // The handler can run again before the monitor stops.
                let isFirst = answered.withLock { done in
                    defer { done = true }
                    return !done
                }
                guard isFirst else { return }
                monitor.cancel()
                continuation.resume(returning: path.status == .satisfied)
            }
            monitor.start(queue: .global(qos: .userInitiated))
        }
    }
}
