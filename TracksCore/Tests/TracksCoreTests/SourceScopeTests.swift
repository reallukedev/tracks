import Testing
import Foundation
import SwiftData
@testable import TracksCore

/// Telling Apple Music plays from Your Music plays: how a play learns its source, how an old
/// store without one reads, and how the statistics count one source at a time.
@MainActor
@Suite("Apple Music and Your Music apart")
struct SourceScopeTests {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func play(_ title: String, after seconds: TimeInterval, source: PlaySource) -> CaptureStat {
        CaptureStat(
            songKey: title, title: title, artistName: "An Artist",
            capturedAt: start.addingTimeInterval(seconds), kind: .onDemand, source: source
        )
    }

    // MARK: - Where a play came from

    @Test("only Tracks’ own Your Music player marks an observation as Your Music")
    func sourceFromObservation() {
        let local = NowPlayingObservation(
            title: "Song", artistName: "Artist", playbackState: .playing,
            rawFields: [PlaySource.observationKey: PlaySource.yourMusicMarker, "origin": "server"]
        )
        let music = NowPlayingObservation(title: "Song", artistName: "Artist", playbackState: .playing)

        #expect(PlaySource(observation: local) == .yourMusic)
        #expect(PlaySource(observation: music) == .appleMusic)
    }

    @Test("a play with no source, or one this version doesn't know, is Apple Music", arguments: [nil, "", "vinyl"])
    func unknownIsAppleMusic(stored: String?) {
        #expect(PlaySource(stored: stored) == .appleMusic)
    }

    @Test("a capture keeps where its observation came from")
    func captureKeepsSource() throws {
        let store = try TracksStore(inMemory: true)
        let local = NowPlayingObservation(
            title: "Own", artistName: "Artist", playbackState: .playing,
            rawFields: [PlaySource.observationKey: PlaySource.yourMusicMarker]
        )
        let music = NowPlayingObservation(title: "Streamed", artistName: "Artist", playbackState: .playing)

        let own = try store.insertCapture(songKey: "own", catalogSongID: nil, observation: local, kind: .onDemand, session: nil)
        let streamed = try store.insertCapture(songKey: "streamed", catalogSongID: nil, observation: music, kind: .onDemand, session: nil)

        #expect(own.source == .yourMusic)
        #expect(streamed.sourceRawValue == PlaySource.appleMusic.rawValue)
    }

    // MARK: - Migration

    @Test("a store written before sources existed opens, and its plays count as Apple Music")
    func migratesFromFirstSchema() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "TracksSourceMigration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "History.store")

        try writeFirstSchemaStore(at: url)

        let container = try TracksStore.makeContainer(
            ModelConfiguration(schema: TracksStore.schema, url: url, cloudKitDatabase: .none)
        )
        let captures = try container.mainContext.fetch(FetchDescriptor<Capture>())

        let capture = try #require(captures.first)
        #expect(captures.count == 1)
        #expect(capture.title == "Before Sources")
        #expect(capture.sourceRawValue == nil)
        #expect(capture.source == .appleMusic)
    }

    /// A store as the first versioned schema wrote it, closed again before the test opens it.
    private func writeFirstSchemaStore(at url: URL) throws {
        let schema = Schema(versionedSchema: TracksSchemaV1.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        context.insert(TracksSchemaV1.Capture(songID: "1", title: "Before Sources", artistName: "Artist", capturedAt: start))
        try context.save()
    }

    // MARK: - Counting one source

    @Test("a history scoped to one source keeps only its plays")
    func scopedHistoryFilters() {
        let history = ListeningHistory([
            play("streamed", after: 0, source: .appleMusic),
            play("own", after: 100, source: .yourMusic),
            play("streamed again", after: 300, source: .appleMusic),
        ])

        #expect(history.hasYourMusic)
        #expect(history.scoped(to: .yourMusic).captures.map(\.title) == ["own"])
        #expect(history.scoped(to: .appleMusic).captures.map(\.title) == ["streamed", "streamed again"])
        #expect(history.scoped(to: .all).captures.count == 3)
        #expect(history.scoped(to: .appleMusic).hasYourMusic)
    }

    @Test("a scoped play keeps how long it was heard, measured against the whole history")
    func scopedHistoryKeepsListeningTime() {
        let history = ListeningHistory([
            play("streamed", after: 0, source: .appleMusic),
            play("own", after: 100, source: .yourMusic),
            play("streamed again", after: 300, source: .appleMusic),
        ])

        // Ended by the Your Music song after it, not by the next Apple Music one.
        #expect(history.scoped(to: .appleMusic).seconds.first == 100)
    }

    @Test("a song heard first on Apple Music isn't new when Your Music plays it")
    func firstHearingIsAcrossSources() {
        let history = ListeningHistory([
            play("same", after: 0, source: .appleMusic),
            play("same", after: 100, source: .yourMusic),
        ])

        #expect(history.scoped(to: .yourMusic).isFirstHearing == [false])
    }

    @Test("charts count only the scoped plays")
    func chartsFollowScope() {
        let history = ListeningHistory([
            play("streamed", after: 0, source: .appleMusic),
            play("streamed", after: 60, source: .appleMusic),
            play("own", after: 120, source: .yourMusic),
        ])
        let allTime = ChartPeriod(span: .allTime, interval: nil)

        let own = StatsCalculator.songChart(in: allTime, history: history.scoped(to: .yourMusic))
        let everything = StatsCalculator.songChart(in: allTime, history: history)

        #expect(own.map(\.item.title) == ["own"])
        #expect(everything.map(\.item.title) == ["streamed", "own"])
    }

    @Test("the scope applies only with the setting on and Your Music plays to tell apart")
    func effectiveScope() {
        #expect(SourceScope.effective(.yourMusic, separates: false, hasYourMusic: true) == .all)
        #expect(SourceScope.effective(.yourMusic, separates: true, hasYourMusic: false) == .all)
        #expect(SourceScope.effective(.yourMusic, separates: true, hasYourMusic: true) == .yourMusic)
    }
}
