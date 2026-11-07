import Foundation
import Testing
@testable import TracksCore

@Suite("Downloaded audio")
struct DownloadedAudioTests {
    static let errorPage = Data(#"<?xml version="1.0" encoding="UTF-8"?><subsonic-response status="failed" version="1.16.1"><error code="70" message="Song not found"/></subsonic-response>"#.utf8)

    @Test(arguments: [nil, "application/octet-stream", "text/xml", "application/xml"])
    func `a Subsonic error page isn't kept as a song`(mimeType: String?) {
        #expect(!DownloadedAudio.isAudio(mimeType: mimeType, head: Self.errorPage.prefix(DownloadedAudio.headLength), size: Int64(Self.errorPage.count)))
    }

    @Test(arguments: [
        ("audio/flac", Data("fLaC".utf8) + Data(count: 12)),
        ("application/octet-stream", Data("ID3".utf8) + Data(count: 13)),
        ("audio/mpeg", Data([0xFF, 0xFB, 0x90, 0x64]) + Data(count: 12)),
    ])
    func `a song is kept whatever its type says`(mimeType: String, head: Data) {
        #expect(DownloadedAudio.isAudio(mimeType: mimeType, head: head, size: 4_000_000))
        #expect(DownloadedAudio.isAudio(mimeType: mimeType, head: head, size: 30_000))
    }

    @Test func `an empty file isn't a song`() {
        #expect(!DownloadedAudio.isAudio(mimeType: "audio/mpeg", head: Data(), size: 0))
    }
}
