import Testing
@testable import TracksCore

@Suite("Apple Music merge ledger")
struct AppleMusicMergeLedgerTests {
    let apple = "intro|band"
    let here = "intro (remastered)|band"

    func link(seen: [String] = [], matched: [String: String]? = [:]) -> TracksPlaylist.AppleMusicLink {
        TracksPlaylist.AppleMusicLink(playlistID: "p.1", name: "Mix", seen: seen, matched: matched)
    }

    /// Merges once, finding Apple Music's song under another name here, and returns the link
    /// as it's saved.
    func mergedWithMatch() -> TracksPlaylist.AppleMusicLink {
        var ledger = AppleMusicMergeLedger(link: link(), here: [], inApple: [apple])
        #expect(ledger.isNew(apple: apple, here: []))
        ledger.found(apple: apple, here: here)
        ledger.settle(here: [here], inApple: [apple])
        return ledger.written(to: link())
    }

    @Test func `a song found under another name stays at the next merge`() {
        var next = AppleMusicMergeLedger(link: mergedWithMatch(), here: [here], inApple: [apple])
        #expect(next.takeOut(keeping: [apple]).isEmpty)
        #expect(!next.isNew(apple: apple, here: [here]))
        #expect(!next.needsAdding(here: here, inApple: [apple]))
    }

    @Test func `taking a matched song out in Apple Music takes out its name here`() {
        var next = AppleMusicMergeLedger(link: mergedWithMatch(), here: [here], inApple: [])
        #expect(next.takeOut(keeping: []).contains(here))
        #expect(next.needsAdding(here: here, inApple: []))
    }

    @Test func `a song added here under another name stays at the next merge`() {
        var first = AppleMusicMergeLedger(link: link(), here: [here], inApple: [])
        #expect(first.needsAdding(here: here, inApple: []))
        first.added(here: here, apple: apple)
        var next = AppleMusicMergeLedger(link: first.written(to: link()), here: [here], inApple: [apple])
        #expect(next.takeOut(keeping: [apple]).isEmpty)
        #expect(!next.needsAdding(here: here, inApple: [apple]))
    }

    @Test func `a song both had at the first merge comes out when taken out in Apple Music`() {
        var first = AppleMusicMergeLedger(link: link(), here: [apple], inApple: [apple])
        first.settle(here: [apple], inApple: [apple])
        var next = AppleMusicMergeLedger(link: first.written(to: link()), here: [apple], inApple: [])
        #expect(next.takeOut(keeping: []) == [apple])
    }

    @Test func `an older link keeps a song here it can't tell apart`() {
        let older = link(seen: [apple, here], matched: nil)
        var ledger = AppleMusicMergeLedger(link: older, here: [here], inApple: [apple])
        #expect(ledger.takeOut(keeping: [apple]).isEmpty)
        #expect(!ledger.needsAdding(here: here, inApple: [apple]))
    }

    @Test func `a song Apple Music's catalog doesn't have isn't added again`() {
        var ledger = AppleMusicMergeLedger(link: link(), here: [here], inApple: [])
        ledger.notInCatalog(here: here)
        let next = AppleMusicMergeLedger(link: ledger.written(to: link()), here: [here], inApple: [])
        #expect(!next.needsAdding(here: here, inApple: []))
    }
}
