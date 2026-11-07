import Testing
import Foundation
@testable import TracksCore

@Suite("Apple Music library add")
struct AppleMusicLibraryAddTests {

    @Test("adding POSTs the ids under their kind")
    func adds() throws {
        let request = try #require(AppleMusicLibraryAdd.request(adding: ["1440857781", "1440857782"], as: .songs))
        #expect(request.httpMethod == "POST")
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "/v1/me/library")
        #expect(components.queryItems == [URLQueryItem(name: "ids[songs]", value: "1440857781,1440857782")])
    }

    @Test("each kind names its own query", arguments: [
        (AppleMusicLibraryAdd.Kind.albums, "ids[albums]"),
        (.playlists, "ids[playlists]"),
    ])
    func kinds(kind: AppleMusicLibraryAdd.Kind, name: String) throws {
        let request = try #require(AppleMusicLibraryAdd.request(adding: ["42"], as: kind))
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.first?.name == name)
    }

    @Test("items already in the library are left out")
    func libraryIDs() throws {
        let request = try #require(AppleMusicLibraryAdd.request(adding: ["i.abc", "1440857781", "l.def", "p.ghi", ""], as: .songs))
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.first?.value == "1440857781")
    }

    @Test("nothing to add makes no request")
    func nothing() {
        #expect(AppleMusicLibraryAdd.request(adding: ["i.abc"], as: .songs) == nil)
        #expect(AppleMusicLibraryAdd.request(adding: [], as: .albums) == nil)
    }
}
