import Testing
import Foundation
@testable import TracksCore

@Suite("What your devices say to each other")
struct NearbyMessageTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test("a message comes back as it went, behind its length", arguments: [
        NearbyMessage.hello(id: "A1", name: "Luke's Mac", platform: "Mac"),
        .hello(id: "A1", name: "Luke's Mac", platform: "Mac", kind: "iMac"),
        .state(NearbyState(title: "Juno", artist: "Sabrina Carpenter", isPlaying: true, position: 42, duration: 223)),
        .command(.next),
        .pause,
        .seek(84.5),
        .takeOver(NearbyState(title: "Juno", artist: "Sabrina Carpenter", album: "Short n' Sweet", isPlaying: true, position: 42, duration: 223)),
        .takeOver(NearbyState(
            title: "Juno", artist: "Sabrina Carpenter", isPlaying: true, position: 42,
            context: NearbyContext(kind: .album, title: "Short n' Sweet"),
            upNext: [NearbySong(title: "Bed Chem", artist: "Sabrina Carpenter", album: "Short n' Sweet", duration: 171)]
        )),
    ])
    func roundTrip(message: NearbyMessage) throws {
        let framed = try NearbyFraming.frame(message)
        let length = try #require(NearbyFraming.length(of: framed.prefix(4)))
        #expect(length == framed.count - 4)
        let decoded = try NearbyFraming.message(from: framed.dropFirst(4))
        #expect(decoded == message)
    }

    @Test("a hello from a device before kinds were sent still reads, with none")
    func helloWithoutKind() throws {
        let old = Data(#"{"hello":{"id":"A1","name":"Luke's Mac","platform":"Mac"}}"#.utf8)
        #expect(try NearbyFraming.message(from: old) == .hello(id: "A1", name: "Luke's Mac", platform: "Mac", kind: nil))
    }

    @Test("a song playing on is the same song seconds later, and a seek isn't")
    func samenessWhilePlaying() {
        let first = NearbyState(title: "Juno", isPlaying: true, position: 10, duration: 200, sentAt: now)
        var later = first
        later.sentAt = now.addingTimeInterval(3)
        later.position = 13
        #expect(first.isSame(as: later))
        later.position = 90
        #expect(!first.isSame(as: later))
    }

    @Test("a header too long, or not four bytes, is refused")
    func badHeaders() {
        #expect(NearbyFraming.length(of: Data([0x7F, 0xFF, 0xFF, 0xFF])) == nil)
        #expect(NearbyFraming.length(of: Data([0, 1])) == nil)
        #expect(NearbyFraming.length(of: Data([0, 0, 1, 0])) == 256)
    }

    @Test("the position moves on while playing, and stops at the song's end")
    func position() {
        let playing = NearbyState(title: "Juno", isPlaying: true, position: 100, duration: 110, sentAt: now)
        #expect(playing.position(at: now.addingTimeInterval(5)) == 105)
        #expect(playing.position(at: now.addingTimeInterval(60)) == 110)
        let paused = NearbyState(title: "Juno", isPlaying: false, position: 100, duration: 110, sentAt: now)
        #expect(paused.position(at: now.addingTimeInterval(5)) == 100)
    }

    @Test("the same song a moment later isn't worth sending again, a pause is")
    func sameness() {
        let first = NearbyState(title: "Juno", isPlaying: true, position: 10, sentAt: now)
        var later = first
        later.sentAt = now.addingTimeInterval(1)
        later.position = 11
        #expect(first.isSame(as: later))
        var paused = later
        paused.isPlaying = false
        #expect(!first.isSame(as: paused))
    }

    @Test("a song from a device before queues were sent still reads, with none, and carries on alone")
    func stateWithoutQueue() throws {
        let old = Data(#"{"takeOver":{"_0":{"title":"Juno","artist":"Sabrina Carpenter","isPlaying":true,"sentAt":0,"canSkipBack":true,"canSkipForward":true}}}"#.utf8)
        guard case .takeOver(let state) = try NearbyFraming.message(from: old) else {
            Issue.record("Expected a takeOver")
            return
        }
        #expect(state.context == nil)
        #expect(state.upNext == nil)
        #expect(state.carry(bringsQueue: true) == .song)
    }

    @Test("a context of a kind this version doesn't know still reads, and is named for the device")
    func unknownContextKind() throws {
        let body = Data(#"{"state":{"_0":{"title":"Juno","isPlaying":true,"sentAt":0,"canSkipBack":true,"canSkipForward":true,"context":{"kindName":"podcast","title":"Later"},"upNext":[{"title":"Bed Chem","artist":"Sabrina Carpenter"}]}}}"#.utf8)
        guard case .state(let state) = try NearbyFraming.message(from: body) else {
            Issue.record("Expected a state")
            return
        }
        #expect(state.context?.kind == nil)
        #expect(state.carry(bringsQueue: true) == .queue(nil, [NearbySong(title: "Bed Chem", artist: "Sabrina Carpenter")]))
    }

    @Test("how a song carries on, by what it's playing from")
    func carry() {
        let next = (1...20).map { NearbySong(title: "Song \($0)", artist: "Artist") }
        let album = NearbyContext(kind: .album, title: "Short n' Sweet")
        let radio = NearbyContext(kind: .endless, title: "Tracks Radio")
        func state(_ context: NearbyContext?, _ upNext: [NearbySong]?) -> NearbyState {
            NearbyState(title: "Juno", artist: "Sabrina Carpenter", isPlaying: true, context: context, upNext: upNext)
        }

        // Up Next comes along, as many songs as are carried, behind what it's playing from.
        #expect(state(album, next).carry(bringsQueue: true) == .queue(album, Array(next.prefix(NearbyState.carriedSongs))))
        // The last song of an album still brings the album.
        #expect(state(album, []).carry(bringsQueue: true) == .queue(album, []))
        // Turned off, it's the song alone, whatever came with it.
        #expect(state(album, next).carry(bringsQueue: false) == .song)
        #expect(state(radio, nil).carry(bringsQueue: false) == .song)
        // A live mix picks again from the song rather than bringing its picks.
        #expect(state(radio, next).carry(bringsQueue: true) == .live(radio))
        // A station's songs can't be queued.
        #expect(state(NearbyContext(kind: .station, title: "Hits"), next).carry(bringsQueue: true) == .song)
        // Songs with nothing to name them by are named for the device: the device's own label
        // from an earlier move isn't carried back.
        let moved = NearbyContext(kind: .songs, title: "From Luke's iPhone")
        #expect(state(moved, Array(next.prefix(2))).carry(bringsQueue: true) == .queue(nil, Array(next.prefix(2))))
        #expect(state(moved, []).carry(bringsQueue: true) == .song)
        #expect(state(nil, nil).carry(bringsQueue: true) == .song)
    }
}
