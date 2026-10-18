import Foundation
import SwiftData
import Testing
@testable import TracksCore

/// The merge that reads only the songs with duplicates must leave exactly what the merge
/// that reads everything leaves. Two devices can run different ones, and if they disagreed
/// about which row to keep, each would delete the other's and the play would be lost.
@MainActor
@Suite("Merging only the songs with duplicates")
struct TargetedMergeTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let policy = DedupePolicy()

    private struct Play: Hashable {
        let title: String
        let artist: String
        let offset: TimeInterval
        let kind: CaptureKind
        let device: String
    }

    /// A few songs, spelled more than one way, played by two devices at every kind of
    /// distance: seconds apart, just inside and outside the ordinary window, hours apart
    /// with imports among them, and days apart.
    private static func plays(seed: UInt64) -> [Play] {
        var random = SeededRandom(seed: seed)
        let songs = [("Fireside", "Giant Book Sale"), ("fireside ", "GIANT BOOK SALE"), ("Café", "Mara Solís"),
                     ("Cafe", "Mara Solis"), ("Tides", "Low Hum"), ("Alone", "Nobody")]
        let gaps: [TimeInterval] = [0, 5, 30, 9 * 60, 11 * 60, 45 * 60, 5 * 3_600, 23 * 3_600, 25 * 3_600, 3 * 86_400]
        let kinds: [CaptureKind] = [.radio, .onDemand, .imported]
        var clock: TimeInterval = 0
        return (0..<120).map { _ in
            clock += gaps[Int(random.next() % UInt64(gaps.count))]
            let song = songs[Int(random.next() % UInt64(songs.count))]
            return Play(
                title: song.0,
                artist: song.1,
                offset: clock,
                kind: kinds[Int(random.next() % 3)],
                device: random.next() % 2 == 0 ? "mac" : "iphone"
            )
        }
    }

    private func store(with plays: [Play]) throws -> TracksStore {
        let store = try TracksStore(inMemory: true)
        for play in plays {
            store.context.insert(Capture(
                songID: "1", songKey: play.title, title: play.title, artistName: play.artist,
                kind: play.kind, capturedAt: start.addingTimeInterval(play.offset), deviceID: play.device
            ))
        }
        try store.context.save()
        return store
    }

    private func remaining(_ store: TracksStore) throws -> [String] {
        try store.context.fetch(TracksStore.allCaptures()).map {
            "\($0.title)|\($0.artistName)|\($0.capturedAt.timeIntervalSince(start))|\($0.kind)|\($0.capturedByDeviceID)"
        }
        .sorted()
    }

    @Test("leaves the same plays as merging everything", arguments: [1, 2, 3, 4, 5, 6, 7, 8] as [UInt64])
    func matchesFullMerge(seed: UInt64) async throws {
        let plays = Self.plays(seed: seed)
        let everything = try store(with: plays)
        let targeted = try store(with: plays)

        let fullCount = try everything.mergeDuplicateCaptures(policy: policy)
        let targetedCount = try await targeted.mergeDuplicatePlays(policy: policy)

        // Otherwise the two would trivially agree.
        #expect(fullCount > 0)
        #expect(targetedCount == fullCount)
        #expect(try remaining(targeted) == remaining(everything))
    }

    @Test("with no duplicates it merges nothing")
    func nothingToMerge() async throws {
        let store = try store(with: [
            Play(title: "One", artist: "A", offset: 0, kind: .radio, device: "mac"),
            Play(title: "One", artist: "A", offset: 3_600, kind: .onDemand, device: "mac"),
            Play(title: "Two", artist: "A", offset: 60, kind: .radio, device: "mac"),
        ])

        #expect(try await store.mergeDuplicatePlays(policy: policy) == 0)
        #expect(try store.context.fetchCount(FetchDescriptor<Capture>()) == 3)
    }

    @Test("a second merge finds nothing more")
    func idempotent() async throws {
        let store = try store(with: Self.plays(seed: 42))

        #expect(try await store.mergeDuplicatePlays(policy: policy) > 0)
        #expect(try await store.mergeDuplicatePlays(policy: policy) == 0)
        #expect(try store.mergeDuplicateCaptures(policy: policy) == 0)
    }

    @Test("a duplicate that arrives after the first merge is merged by the next")
    func laterDuplicate() async throws {
        let store = try store(with: [Play(title: "One", artist: "A", offset: 0, kind: .onDemand, device: "mac")])
        #expect(try await store.mergeDuplicatePlays(policy: policy) == 0)

        store.context.insert(Capture(
            songID: "1", title: "One", artistName: "A", kind: .imported,
            capturedAt: start.addingTimeInterval(1_800), deviceID: "iphone"
        ))
        try store.context.save()

        #expect(try await store.mergeDuplicatePlays(policy: policy) == 1)
        let survivor = try #require(try store.context.fetch(TracksStore.allCaptures()).first)
        #expect(survivor.kind == .onDemand)
    }

    @Test("only covers that can't load are cleared", arguments: [
        ("musicKit://artwork/transient/1", true),
        ("https://is1-ssl.mzstatic.com/a.jpg", false),
        ("http://example.com/a.jpg", false),
        ("HTTPS://EXAMPLE.COM/A.JPG", false),
        ("", true),
        ("file:///tmp/a.jpg", true),
    ])
    func clearsOnlyUnloadable(url: String, cleared: Bool) throws {
        let store = try TracksStore(inMemory: true)
        let capture = Capture(songID: "1", title: "T", artistName: "A", artworkURL: url, deviceID: "d")
        let without = Capture(songID: "2", title: "U", artistName: "A", deviceID: "d")
        store.context.insert(capture)
        store.context.insert(without)
        try store.context.save()

        #expect(try store.clearUnloadableArtwork() == (cleared ? 1 : 0))
        #expect(capture.artworkURL == (cleared ? nil : url))
        #expect(without.artworkURL == nil)
    }
}

/// SplitMix64, so the generated histories are the same on every run.
private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
