import Testing
import Foundation
@testable import TracksCore

private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let juno = SharePlaySong(catalogID: "1750307020", title: "Juno", artistName: "Sabrina Carpenter", albumTitle: "Short n' Sweet", artworkURL: "https://example.com/juno.jpg")
private let espresso = SharePlaySong(catalogID: "1750307010", title: "Espresso", artistName: "Sabrina Carpenter", isExplicit: true)
private let alice = UUID()
private let bob = UUID()

private func snapshot(isStation: Bool = false, allowsExplicit: Bool = true, upNext: [SharePlayTrack] = []) -> SharePlaySnapshot {
    SharePlaySnapshot(
        nowPlaying: SharePlayTrack(id: "q1", title: "Good Luck, Babe!", artistName: "Chappell Roan"),
        isPlaying: true,
        upNext: upNext,
        isStation: isStation,
        allowsExplicit: allowsExplicit
    )
}

@Suite("What SharePlay says")
struct SharePlayMessageTests {
    @Test("a message comes back as it went", arguments: [
        SharePlayMessage.hello,
        .ended,
        .snapshot(snapshot(upNext: [SharePlayTrack(id: "q2", title: "Juno", artistName: "Sabrina Carpenter", isFromSharePlay: true)])),
        .snapshot(SharePlaySnapshot(source: .yourMusic, isStation: true, allowsExplicit: false)),
        .add(SharePlayAddRequest(id: UUID(), song: juno, placement: .next)),
        .reply(SharePlayAddReply(requestID: UUID(), outcome: .added(.last))),
        .reply(SharePlayAddReply(requestID: UUID(), outcome: .refused(.station))),
    ])
    func roundTrip(message: SharePlayMessage) throws {
        let data = try JSONEncoder().encode(message)
        #expect(try JSONDecoder().decode(SharePlayMessage.self, from: data) == message)
    }

    @Test("a snapshot carries fifteen of Up Next, and counts the rest")
    func upNextLimit() {
        let tracks = (0..<40).map { SharePlayTrack(id: "q\($0)", title: "Song \($0)", artistName: "Artist") }
        let sent = SharePlaySnapshot(upNext: tracks, upNextCount: 40)
        #expect(sent.upNext.count == SharePlaySnapshot.upNextLimit)
        #expect(sent.upNextCount == 40)
    }

    @Test("a song is known by its name, whichever copy of it the host found")
    func identity() {
        let track = SharePlayTrack(id: "local-7", title: "juno", artistName: "sabrina carpenter")
        #expect(track.identity == juno.identity)
    }
}

@Suite("The host's first look at a request")
struct SharePlayGateTests {
    @Test("a song goes in once, however fast it's tapped")
    func doubleTap() {
        var gate = SharePlayGate()
        let first = SharePlayAddRequest(song: juno, placement: .last)
        let second = SharePlayAddRequest(song: juno, placement: .last)
        #expect(gate.check(first, from: alice, at: now, queued: [], isStation: false) == .accept)
        #expect(gate.check(second, from: alice, at: now.addingTimeInterval(0.3), queued: [], isStation: false) == .refuse(.alreadyQueued))
    }

    @Test("the same request arriving twice is answered once")
    func repeatedRequest() {
        var gate = SharePlayGate()
        let request = SharePlayAddRequest(song: juno, placement: .next)
        #expect(gate.check(request, from: alice, at: now, queued: [], isStation: false) == .accept)
        #expect(gate.check(request, from: alice, at: now, queued: [], isStation: false) == .ignore)
    }

    @Test("a song already coming up isn't added again, whoever asks")
    func alreadyQueued() {
        var gate = SharePlayGate()
        #expect(gate.check(SharePlayAddRequest(song: juno, placement: .last), from: alice, at: now, queued: [juno.identity], isStation: false) == .refuse(.alreadyQueued))
        #expect(gate.check(SharePlayAddRequest(song: juno, placement: .last), from: bob, at: now, queued: [], isStation: false) == .accept)
        #expect(gate.check(SharePlayAddRequest(song: juno, placement: .last), from: alice, at: now.addingTimeInterval(2), queued: [], isStation: false) == .refuse(.alreadyQueued))
    }

    @Test("a station has no queue: adding is refused rather than replacing it")
    func station() {
        var gate = SharePlayGate()
        #expect(gate.check(SharePlayAddRequest(song: juno, placement: .last), from: alice, at: now, queued: [], isStation: true) == .refuse(.station))
    }

    @Test("a burst is capped per person, and eases off after the window")
    func burst() {
        var gate = SharePlayGate(burst: 3, window: 60)
        let songs = (0..<5).map { SharePlaySong(catalogID: "\($0)", title: "Song \($0)", artistName: "Artist") }
        let answers = songs.enumerated().map { index, song in
            gate.check(SharePlayAddRequest(song: song, placement: .last), from: alice, at: now.addingTimeInterval(Double(index)), queued: [], isStation: false)
        }
        #expect(answers == [.accept, .accept, .accept, .refuse(.tooMany), .refuse(.tooMany)])
        // Someone else still has their own few.
        #expect(gate.check(SharePlayAddRequest(song: juno, placement: .last), from: bob, at: now.addingTimeInterval(5), queued: [], isStation: false) == .accept)
        // A minute on, there's room again.
        #expect(gate.check(SharePlayAddRequest(song: espresso, placement: .last), from: alice, at: now.addingTimeInterval(61), queued: [], isStation: false) == .accept)
    }

    @Test("a song that couldn't go in can be asked for again")
    func release() {
        var gate = SharePlayGate()
        let request = SharePlayAddRequest(song: juno, placement: .last)
        #expect(gate.check(request, from: alice, at: now, queued: [], isStation: false) == .accept)
        gate.release(request, from: alice)
        #expect(gate.check(SharePlayAddRequest(song: juno, placement: .last), from: alice, at: now.addingTimeInterval(1), queued: [], isStation: false) == .accept)
    }
}

@Suite("Telling the group what's on")
struct SharePlayBroadcastTests {
    @Test("only a change is sent, and everything again for someone new")
    func diffing() throws {
        var broadcast = SharePlayBroadcast()
        let playing = snapshot()
        #expect(broadcast.next(playing) == playing)
        #expect(broadcast.next(playing) == nil)

        var paused = playing
        paused.isPlaying = false
        #expect(broadcast.next(paused) == paused)

        broadcast.resend()
        #expect(broadcast.next(paused) == paused)
    }

    @Test("rows from SharePlay are forgotten once they've played")
    func ledger() {
        var ledger = SharePlayLedger()
        ledger.record(juno.identity)
        ledger.record(espresso.identity)
        ledger.prune(keeping: [juno.identity])
        #expect(ledger.contains(juno.identity))
        #expect(!ledger.contains(espresso.identity))
    }
}

@Suite("A guest's side of SharePlay")
struct SharePlayGuestTests {
    @Test("nothing can be sent before the host has said what's on")
    func joining() {
        var guest = SharePlayGuest()
        #expect(guest.phase == .joining)
        #expect(guest.add(juno, placement: .last, at: now) == nil)
        guest.receive(snapshot())
        #expect(guest.phase == .joined)
    }

    @Test("a pick is sent once, then marked with the host's answer")
    func answered() throws {
        var guest = SharePlayGuest()
        guest.receive(snapshot())
        let sent = guest.add(juno, placement: .next, at: now)
        let request = try #require(sent)
        #expect(guest.state(of: juno.catalogID) == .sending)
        #expect(guest.add(juno, placement: .next, at: now) == nil)
        guest.receive(SharePlayAddReply(requestID: request.id, outcome: .added(.next)))
        #expect(guest.state(of: juno.catalogID) == .added(.next))
        #expect(guest.add(juno, placement: .last, at: now) == nil)
    }

    @Test("a song that didn't make it says why, and can be tried again")
    func refused() throws {
        var guest = SharePlayGuest()
        guest.receive(snapshot())
        let sent = guest.add(juno, placement: .last, at: now)
        let request = try #require(sent)
        guest.receive(SharePlayAddReply(requestID: request.id, outcome: .refused(.notFound)))
        #expect(guest.state(of: juno.catalogID) == .notAdded(.notFound))
        #expect(guest.add(juno, placement: .last, at: now) != nil)
    }

    @Test("on a station, or with explicit songs off there, nothing is sent")
    func refusedHere() {
        var station = SharePlayGuest()
        station.receive(snapshot(isStation: true))
        #expect(station.add(juno, placement: .last, at: now) == nil)
        #expect(station.state(of: juno.catalogID) == .notAdded(.station))

        var clean = SharePlayGuest()
        clean.receive(snapshot(allowsExplicit: false))
        #expect(clean.add(espresso, placement: .last, at: now) == nil)
        #expect(clean.state(of: espresso.catalogID) == .notAdded(.explicit))
    }

    @Test("an unanswered pick gives up after a while")
    func timeout() throws {
        var guest = SharePlayGuest()
        guest.receive(snapshot())
        let sent = guest.add(juno, placement: .last, at: now)
        #expect(sent != nil)
        guest.expire(at: now.addingTimeInterval(5))
        #expect(guest.state(of: juno.catalogID) == .sending)
        guest.expire(at: now.addingTimeInterval(SharePlayGuest.answerTimeout))
        #expect(guest.state(of: juno.catalogID) == .notAdded(.noAnswer))
        #expect(!guest.hasPending)
    }

    @Test("when the host ends it, the page stays with what's left unanswered marked")
    func ended() throws {
        var guest = SharePlayGuest()
        guest.receive(snapshot())
        let sent = guest.add(juno, placement: .last, at: now)
        #expect(sent != nil)
        guest.end()
        #expect(guest.phase == .ended)
        #expect(guest.state(of: juno.catalogID) == .notAdded(.noAnswer))
        // A late snapshot doesn't bring it back.
        guest.receive(snapshot())
        #expect(guest.phase == .ended)
    }
}
