import Foundation
import TracksCore

/// What was on when Tracks last closed: the song, where it had got to, and what was due after
/// it, so the next launch can open on it, paused, rather than on nothing.
nonisolated struct LastSession: Codable, Sendable {
    /// The song that was on, then Up Next.
    var tracks: [PlayerTrack]
    /// How far into the first one.
    var time: TimeInterval
    var contextKind: String?
    var contextTitle: String?
    var savedAt: Date

    /// Songs after the one on that are worth keeping: a long queue from a playlist of
    /// thousands would make every save slow for songs rarely reached.
    static let keptAhead = 200

    @MainActor var context: PlayContext? {
        guard let contextTitle else { return nil }
        let kind: PlayContext.Kind = switch contextKind {
        case "album": .album
        case "playlist": .playlist
        case "artist": .artist
        case "mix": .mix
        // Tracks Radio or a mood, which picks up live again when it's played.
        case "endless": .endless
        default: .songs
        }
        return PlayContext(kind: kind, title: contextTitle)
    }

    /// Whether the songs are from your own music, which only its player can play.
    var isYourMusic: Bool { tracks.first?.local != nil }
}

extension PlayContext.Kind {
    var storedName: String {
        switch self {
        case .station: "station"
        case .mix: "mix"
        case .album: "album"
        case .playlist: "playlist"
        case .artist: "artist"
        case .songs: "songs"
        case .endless: "endless"
        }
    }
}

/// Keeps ``LastSession`` in a file of its own in Application Support, beside nothing else.
enum LastSessionStore {
    /// Whether Tracks opens on the song left paused. On by default.
    static let resumesKey = "playResumesLastSession"
    /// How long it waits for you. See ``ResumeWindow``.
    static let windowKey = "playResumeWindow"

    static var resumes: Bool {
        UserDefaults.standard.object(forKey: resumesKey) as? Bool ?? true
    }

    static var window: ResumeWindow {
        UserDefaults.standard.string(forKey: windowKey).flatMap(ResumeWindow.init(rawValue:)) ?? .standard
    }

    private static var url: URL {
        URL.applicationSupportDirectory.appending(path: "Last Session.json")
    }

    static func save(_ session: LastSession?) {
        guard let session else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder().encode(session) else { return }
        write(data)
    }

    /// A long queue of songs, each with its artwork, is slow to encode: off the main actor
    /// for the saves made while playing.
    @concurrent
    static func encoded(_ session: LastSession) async -> Data? {
        try? JSONEncoder().encode(session)
    }

    static func write(_ data: Data) {
        do {
            try FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // Losing a paused song is a small thing; the next save tries again.
        }
    }

    /// The session to open on, if the setting is on and it hasn't waited too long.
    static func load(now: Date = .now) -> LastSession? {
        guard resumes,
              let data = try? Data(contentsOf: url),
              let session = try? JSONDecoder().decode(LastSession.self, from: data),
              !session.tracks.isEmpty,
              window.keeps(savedAt: session.savedAt, now: now)
        else { return nil }
        return session
    }
}
