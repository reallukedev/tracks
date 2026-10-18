import Foundation
import SwiftData
import Testing
@testable import TracksCore

/// Timings for a heavy listener's library, to find what grows with the history.
///
/// Everything here runs after every song or on every screen, so each should stay well under
/// a frame's worth of main-actor time, or happen in the background. The first read is the
/// one exception: it reads the whole history, once per launch, in the background.
///
/// Off by default: it seeds a hundred and fifty thousand rows. Run it on its own, in release:
///
///     TRACKS_BENCHMARK=1 swift test -c release --filter LargeLibraryBenchmarks
@MainActor
@Suite(
    "Large library timings",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["TRACKS_BENCHMARK"] != nil)
)
struct LargeLibraryBenchmarks {
    /// About eighty songs a day for five years.
    static let playCount = 150_000
    static let songCount = 25_000
    static let artistCount = 4_000

    @Test("time the work that scales with history")
    func timings() async throws {
        let store = try TracksStore(inMemory: true)
        let now = Date.now
        try seed(store, now: now)
        store.context.processPendingChanges()

        let reader = ListeningHistoryReader(container: store.container)
        let clock = ContinuousClock()
        var snapshot: ListeningHistoryReader.Snapshot?
        var elapsed = try await clock.measure { snapshot = try await reader.read() }
        print("⏱ [reader] first read: \(elapsed)")
        store.context.insert(Capture(songID: "1", title: "New", artistName: "Someone", kind: .onDemand, capturedAt: now))
        try store.context.save()
        elapsed = try await clock.measure { snapshot = try await reader.read() }
        print("⏱ [reader] read after one new song: \(elapsed), \(snapshot?.captures.count ?? 0) plays")
        let current = try #require(snapshot)
        elapsed = try await clock.measure { snapshot = try await reader.read() }
        print("⏱ [reader] read with nothing new: \(elapsed)")

        let history = measure("build ListeningHistory") { ListeningHistory(current.captures) }

        for range in StatsRange.allCases {
            _ = measure("summary \(range)") {
                StatsCalculator.summary(range: range, history: history, sessions: [], now: now)
            }
        }
        _ = measure("song chart, all time") { StatsCalculator.songChart(range: .allTime, history: history, now: now) }
        _ = measure("artist chart, all time") { StatsCalculator.artistChart(range: .allTime, history: history, now: now) }
        _ = measure("album chart, all time") { StatsCalculator.albumChart(range: .allTime, history: history, now: now) }
        let index = measure("build search index") { SearchIndex(history: history) }
        _ = measure("search \"lo\" with the index") { index.search("lo") }
        _ = measure("search \"song 12 love\" with the index") { index.search("song 12 love") }
        let song = history.captures[history.captures.count - 1]
        _ = measure("song profile") { StatsCalculator.songProfile(id: song.songIdentity, history: history, now: now) }
        _ = measure("artist profile") { StatsCalculator.artistProfile(id: song.artistIdentity, history: history, now: now) }

        do {
            let clock = ContinuousClock()
            var merged = 0
            var elapsed = try await clock.measure { merged = try await store.mergeDuplicatePlays() }
            print("⏱ [merge] targeted merge, first run: \(elapsed), merged \(merged)")
            elapsed = try await clock.measure { merged = try await store.mergeDuplicatePlays() }
            print("⏱ [merge] targeted merge, nothing new: \(elapsed), merged \(merged)")
            var groups: [[PersistentIdentifier]] = []
            elapsed = try await clock.measure { groups = try await store.historyReader.duplicatePlayGroups(policy: DedupePolicy()) }
            print("⏱ [merge] finding groups in the background: \(elapsed), \(groups.count) groups")
        }
        _ = try measure("full merge, after the targeted one") { try store.mergeDuplicateCaptures() }
        _ = try measure("clear unloadable artwork") { try store.clearUnloadableArtwork() }
        _ = try measure("count captures") { try store.context.fetchCount(FetchDescriptor<Capture>()) }
    }

    private func seed(_ store: TracksStore, now: Date) throws {
        var random = SystemRandomNumberGenerator()
        let station = Station(name: "Apple Music Chill", firstSeenAt: now.addingTimeInterval(-5 * 365 * 86_400))
        store.context.insert(station)
        var session: Session?
        let spacing = (5 * 365 * 86_400.0) / Double(Self.playCount)
        let start = now.addingTimeInterval(-5 * 365 * 86_400)

        for index in 0..<Self.playCount {
            // Skewed towards a few favourites, as real listening is.
            let song = Int(Double(Self.songCount) * pow(Double.random(in: 0..<1, using: &random), 2.5))
            let artist = song % Self.artistCount
            let capturedAt = start.addingTimeInterval(Double(index) * spacing)
            let kind: CaptureKind = [.radio, .onDemand, .imported][index % 3]
            if kind == .radio, index % 30 == 0 {
                session?.endedAt = session?.lastActivityAt
                let new = Session(startedAt: capturedAt, station: station)
                store.context.insert(new)
                session = new
            }
            let capture = Capture(
                songID: "\(1_000_000 + song)",
                title: "Song \(song) love",
                artistName: "Artist \(artist)",
                albumTitle: "Album \(song / 8)",
                artworkURL: "https://is1-ssl.mzstatic.com/image/thumb/\(song / 8)/300x300bb.jpg",
                kind: kind,
                capturedAt: capturedAt,
                session: kind == .radio ? session : nil
            )
            session?.lastActivityAt = capturedAt
            store.context.insert(capture)
            if index % 10_000 == 9_999 { try store.context.save() }
        }
        try store.context.save()
    }

    @discardableResult
    private func measure<T>(_ label: String, _ work: () throws -> T) rethrows -> T {
        let clock = ContinuousClock()
        var result: T?
        let elapsed = try clock.measure { result = try work() }
        let milliseconds = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        print("⏱ \(label): \(String(format: "%.0f", milliseconds)) ms")
        return result!
    }
}
