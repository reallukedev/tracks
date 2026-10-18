import Testing
import Foundation
import SwiftData
@testable import TracksCore

/// Bringing history over from Motif: everything comes across once, and nothing twice.
@MainActor
@Suite("Bringing over Motif's history")
struct MotifImportTests {
    let motif: TracksStore
    let tracks: TracksStore
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    init() throws {
        motif = try TracksStore(inMemory: true)
        tracks = try TracksStore(inMemory: true)
    }

    /// Two radio plays in an open session on a station, and one on-demand play.
    func fillMotif() throws {
        let station = Station(name: "Chill Radio", firstSeenAt: start)
        motif.context.insert(station)
        let session = Session(startedAt: start, station: station, deviceID: "motif-iphone")
        motif.context.insert(session)
        for (index, title) in ["Sunday", "Morning"].enumerated() {
            let play = Capture(songID: "\(index)", title: title, artistName: "Artist", kind: .radio,
                               capturedAt: start.addingTimeInterval(Double(index) * 200),
                               deviceID: "motif-iphone", session: session)
            play.scrobbledAt = play.capturedAt
            motif.context.insert(play)
        }
        motif.context.insert(Capture(songID: "9", title: "Chosen", artistName: "Other", kind: .onDemand,
                                     capturedAt: start.addingTimeInterval(1_000), deviceID: "motif-mac"))
        try motif.context.save()
    }

    @Test("plays, sessions and stations come across with what Motif knew about them")
    func copiesEverything() throws {
        try fillMotif()
        let outcome = try MotifImport.copyHistory(from: motif.container, into: tracks.container)
        #expect(outcome == .init(plays: 3, skipped: 0, sessions: 1, stations: 1))

        let plays = try tracks.context.fetch(FetchDescriptor<Capture>(sortBy: [SortDescriptor(\.capturedAt)]))
        #expect(plays.map(\.title) == ["Sunday", "Morning", "Chosen"])
        #expect(plays[0].session?.station?.name == "Chill Radio")
        // Still Motif's device, so Tracks never writes or scrobbles them again.
        #expect(plays.map(\.capturedByDeviceID) == ["motif-iphone", "motif-iphone", "motif-mac"])
        #expect(plays[0].scrobbledAt == start)
        #expect(plays[2].kind == .onDemand)
        // Nothing on Motif's side will ever close its open session.
        #expect(try tracks.context.fetch(FetchDescriptor<Session>()).first?.endedAt != nil)
    }

    @Test("running it again adds nothing")
    func runsTwiceSafely() throws {
        try fillMotif()
        _ = try MotifImport.copyHistory(from: motif.container, into: tracks.container)
        let again = try MotifImport.copyHistory(from: motif.container, into: tracks.container)
        #expect(again == .init(plays: 0, skipped: 3, sessions: 0, stations: 0))
        #expect(try tracks.context.fetchCount(FetchDescriptor<Capture>()) == 3)
    }

    @Test("a play the store merged into its twin isn't brought back")
    func respectsMerges() throws {
        for minutes in [0.0, 2] {
            motif.context.insert(Capture(songID: "1", title: "Twice", artistName: "Artist", kind: .radio,
                                         capturedAt: start.addingTimeInterval(minutes * 60), deviceID: "motif-iphone"))
        }
        try motif.context.save()

        #expect(try MotifImport.copyHistory(from: motif.container, into: tracks.container).plays == 2)
        #expect(try tracks.mergeDuplicateCaptures() == 1)
        let again = try MotifImport.copyHistory(from: motif.container, into: tracks.container)
        #expect(again.plays == 0)
        #expect(try tracks.context.fetchCount(FetchDescriptor<Capture>()) == 1)
    }

    @Test("a play Tracks already has is kept once, and a station is shared")
    func mergesWithTracks() throws {
        try fillMotif()
        let station = Station(name: "chill radio", firstSeenAt: start.addingTimeInterval(50))
        tracks.context.insert(station)
        tracks.context.insert(Capture(songID: "0", title: "Sunday", artistName: "Artist", kind: .radio,
                                      capturedAt: start, deviceID: "tracks"))
        try tracks.context.save()

        let outcome = try MotifImport.copyHistory(from: motif.container, into: tracks.container)
        #expect(outcome.plays == 2)
        #expect(outcome.skipped == 1)
        #expect(outcome.stations == 0)
        // Read fresh: the import saved through its own context.
        let stations = try ModelContext(tracks.container).fetch(FetchDescriptor<Station>())
        #expect(stations.count == 1)
        #expect(stations.first?.firstSeenAt == start)
    }

    @Test("the store and its log are copied together when nothing is writing")
    func copiesTheFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "MotifCopyTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = folder.appending(path: "default.store")
        try Data("store".utf8).write(to: store)
        try Data("log".utf8).write(to: URL(filePath: store.path(percentEncoded: false) + "-wal"))

        let copy = try await MotifImport.copyStore(at: store)
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }

        #expect(try Data(contentsOf: copy) == Data("store".utf8))
        #expect(try Data(contentsOf: URL(filePath: copy.path(percentEncoded: false) + "-wal")) == Data("log".utf8))
    }

    /// Imports a copy of a real Motif store: set `MOTIF_STORE_COPY` to its path.
    @Test("a real Motif store", .enabled(if: ProcessInfo.processInfo.environment["MOTIF_STORE_COPY"] != nil))
    func realStore() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["MOTIF_STORE_COPY"])
        let copy = try await MotifImport.copyStore(at: URL(filePath: path))
        let source = try TracksStore.makeContainer(ModelConfiguration(
            schema: TracksStore.schema, url: copy, allowsSave: true, cloudKitDatabase: .none
        ))
        let motifPlays = try ModelContext(source).fetchCount(FetchDescriptor<Capture>())
        let outcome = try MotifImport.copyHistory(from: source, into: tracks.container)
        print("Motif had \(motifPlays) plays; brought over \(outcome.plays), skipped \(outcome.skipped), \(outcome.sessions) sessions, \(outcome.stations) stations")
        #expect(outcome.plays + outcome.skipped == motifPlays)
        #expect(try tracks.context.fetchCount(FetchDescriptor<Capture>()) == outcome.plays)
        let again = try MotifImport.copyHistory(from: source, into: tracks.container)
        #expect(again.plays == 0)
    }
}
