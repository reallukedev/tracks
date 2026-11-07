import Testing
import Foundation
import SwiftData
@testable import TracksCore

/// The store side of repairing artwork: listing the covers to check, and forgetting the ones
/// that turned out to be broken.
@MainActor
@Suite("Stored artwork")
struct StoreArtworkTests {
    let store: TracksStore

    init() throws {
        store = try TracksStore(inMemory: true)
    }

    @discardableResult
    private func add(_ title: String, cover: String?) throws -> Capture? {
        try store.recordCapture(
            songID: title,
            title: title,
            artistName: "An Artist",
            artworkURL: cover,
            now: .now
        )
    }

    @Test("every cover address is listed once, however many songs share it")
    func listsDistinctAddresses() async throws {
        try add("One", cover: "https://example.test/album.jpg")
        try add("Two", cover: "https://example.test/album.jpg")
        try add("Three", cover: "https://example.test/other.jpg")
        try add("Four", cover: nil)

        #expect(try await Set(store.artworkURLs()) == [
            "https://example.test/album.jpg",
            "https://example.test/other.jpg",
        ])
    }

    @Test("clearing a cover blanks every song that had it, and leaves the rest alone")
    func clearsSharedCover() throws {
        try add("One", cover: "https://example.test/album.jpg")
        try add("Two", cover: "https://example.test/album.jpg")
        try add("Three", cover: "https://example.test/other.jpg")

        #expect(try store.clearArtwork(urls: ["https://example.test/album.jpg"]) == 2)

        let rows = try store.context.fetch(TracksStore.allCaptures())
        #expect(rows.filter { $0.artworkURL == nil }.count == 2)
        #expect(rows.filter { $0.artworkURL == "https://example.test/other.jpg" }.count == 1)
    }

    @Test("clearing nothing touches nothing")
    func clearsNothing() async throws {
        try add("One", cover: "https://example.test/album.jpg")

        #expect(try store.clearArtwork(urls: []) == 0)
        #expect(try await store.artworkURLs() == ["https://example.test/album.jpg"])
    }

    /// The backfill only fills rows with no cover at all, so a `musicKit://` address left in
    /// place would keep the row blank for good.
    @Test("addresses nothing can load are cleared on their own")
    func clearsUnloadable() async throws {
        try add("Stream", cover: "musicKit://artwork/transient/abc")
        try add("Good", cover: "https://example.test/album.jpg")

        #expect(try store.clearUnloadableArtwork() == 1)
        #expect(try await store.artworkURLs() == ["https://example.test/album.jpg"])
    }
}
