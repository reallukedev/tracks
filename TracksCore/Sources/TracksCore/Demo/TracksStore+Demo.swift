import Foundation
import SwiftData

extension TracksStore {
    /// Fills an empty in-memory store with `DemoLibrary` plays. Never call this on the real
    /// store: the rows would sync to iCloud and be queued for Last.fm.
    public func seedDemoData(_ plays: [DemoLibrary.Play]) throws {
        guard case .inMemory = backing else {
            assertionFailure("Demo data belongs in an in-memory store only")
            return
        }

        var stations: [String: Station] = [:]
        var session: Session?
        for play in plays {
            var owner: Session?
            if play.kind == .radio, let name = play.stationName {
                let station = stations[name] ?? {
                    let new = Station(name: name, firstSeenAt: play.capturedAt)
                    context.insert(new)
                    stations[name] = new
                    return new
                }()
                station.lastSeenAt = play.capturedAt
                // A new session whenever the station changes or there's been a long gap.
                if let current = session, current.station === station,
                   play.capturedAt.timeIntervalSince(current.lastActivityAt) < SessionPolicy.default.silenceTimeout {
                    current.lastActivityAt = play.capturedAt
                    owner = current
                } else {
                    session?.endedAt = session?.lastActivityAt
                    let new = Session(startedAt: play.capturedAt, station: station)
                    context.insert(new)
                    session = new
                    owner = new
                }
            }

            let capture = Capture(
                songID: "",
                songKey: HistoryImport.key(title: play.title, artistName: play.artistName),
                title: play.title,
                artistName: play.artistName,
                albumTitle: play.albumTitle,
                kind: play.kind,
                capturedAt: play.capturedAt,
                source: DemoLibrary.source(of: play),
                session: owner
            )
            capture.needsPlaylistWrite = false
            if play.kind == .radio { capture.addedToPlaylistAt = play.capturedAt.addingTimeInterval(45) }
            if play.isScrobbled { capture.scrobbledAt = play.capturedAt.addingTimeInterval(30) }
            if play.isPlayedBack { capture.playedBackAt = play.capturedAt.addingTimeInterval(6 * 3600) }
            context.insert(capture)
        }
        session?.endedAt = session?.lastActivityAt
        try context.save()
    }
}
