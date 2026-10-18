import Testing
import Foundation
@testable import TracksCore

@Suite("A server's address, as someone types it")
struct ServerAddressTests {
    @Test("a home server without a scheme gains http", arguments: [
        ("192.168.1.223:5274", "http://192.168.1.223:5274"),
        ("192.168.1.20", "http://192.168.1.20"),
        ("localhost:4533", "http://localhost:4533"),
        ("navidrome.local", "http://navidrome.local"),
        ("nas", "http://nas"),
        ("music.example.com:4533", "http://music.example.com:4533"),
        ("[fe80::1]:4533", "http://[fe80::1]:4533"),
        ("fe80::1", "http://[fe80::1]"),
    ])
    func homeGainsHTTP(typed: String, expected: String) {
        #expect(ServerAddress.url(from: typed)?.absoluteString == expected)
    }

    @Test("a server on the internet without a scheme gains https", arguments: [
        ("music.example.com", "https://music.example.com"),
        ("music.example.com:443", "https://music.example.com:443"),
        ("example.com/navidrome", "https://example.com/navidrome"),
    ])
    func internetGainsHTTPS(typed: String, expected: String) {
        #expect(ServerAddress.url(from: typed)?.absoluteString == expected)
    }

    @Test("spaces around it and slashes after it go, and a scheme typed is kept", arguments: [
        ("  192.168.1.223:5274/ \n", "http://192.168.1.223:5274"),
        ("https://192.168.1.4:4533//", "https://192.168.1.4:4533"),
        ("HTTP://music.example.com", "http://music.example.com"),
        ("http://music.example.com/sub/", "http://music.example.com/sub"),
    ])
    func tidied(typed: String, expected: String) {
        #expect(ServerAddress.url(from: typed)?.absoluteString == expected)
    }

    @Test("anything that can't be a web server's address is refused", arguments: ["", "   ", "/", "ftp://nope", "http://", "https:///path"])
    func refused(typed: String) {
        #expect(ServerAddress.url(from: typed) == nil)
    }

    @Test("music servers and Lidarr read addresses the same way")
    func sharedByBoth() {
        #expect(SubsonicServer.address(from: "192.168.1.223:5274")?.absoluteString == "http://192.168.1.223:5274")
        #expect(LidarrServer.address(from: "lidarr.example.com")?.absoluteString == "https://lidarr.example.com")
    }
}
