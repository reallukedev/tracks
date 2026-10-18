import Testing
@testable import TracksCore

@Suite("Starting a queue on the song tapped")
struct QueueStartTests {
    let album = ["a", "b", "c", "d", "e"]

    @Test("a queue already on the song is left alone")
    func alreadyThere() {
        let move = QueueStart.correction(wantedID: "c", wantedIndex: 2, listCount: 5, entryIDs: album, current: 2)
        #expect(move == nil)
    }

    @Test("a queue still on its first song moves to the one tapped before playing")
    func onFirstSong() {
        let move = QueueStart.correction(wantedID: "d", wantedIndex: 3, listCount: 5, entryIDs: album, current: 0)
        #expect(move == 3)
    }

    @Test("a queue that isn't on any song yet is put on the one tapped")
    func nowhere() {
        let move = QueueStart.correction(wantedID: "b", wantedIndex: 1, listCount: 5, entryIDs: album, current: nil)
        #expect(move == 1)
    }

    @Test("the same song twice starts on the copy tapped, not the first")
    func repeatedSong() {
        let list = ["a", "b", "a", "c"]
        #expect(QueueStart.correction(wantedID: "a", wantedIndex: 2, listCount: 4, entryIDs: list, current: 0) == 2)
        #expect(QueueStart.correction(wantedID: "a", wantedIndex: 2, listCount: 4, entryIDs: list, current: 2) == nil)
    }

    @Test("songs the player left out move the tapped one up, and it's found by id")
    func shorterQueue() {
        // "b" couldn't be queued, so "d" is third.
        let entries = ["a", "c", "d", "e"]
        #expect(QueueStart.correction(wantedID: "d", wantedIndex: 3, listCount: 5, entryIDs: entries, current: 0) == 2)
    }

    @Test("songs not yet worked out are found where they were put", arguments: [
        [String?](repeating: nil, count: 5),
        ["x", "y", "z", "w", "v"],
    ])
    func unknownIDs(entries: [String?]) {
        #expect(QueueStart.correction(wantedID: "d", wantedIndex: 3, listCount: 5, entryIDs: entries, current: 0) == 3)
    }

    @Test("a song that can't be found in a queue of another length stays where the player put it")
    func cannotTell() {
        let entries: [String?] = [nil, nil, nil]
        #expect(QueueStart.correction(wantedID: "d", wantedIndex: 3, listCount: 5, entryIDs: entries, current: 0) == nil)
        #expect(QueueStart.correction(wantedID: "d", wantedIndex: 3, listCount: 5, entryIDs: [], current: nil) == nil)
    }
}
