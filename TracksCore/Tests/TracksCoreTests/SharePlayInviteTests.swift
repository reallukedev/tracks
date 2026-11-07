import Testing
import Foundation
@testable import TracksCore

@Suite("SharePlay's code")
struct SharePlayInviteTests {
    @Test("a code's link opens the same invite")
    func linkRoundTrips() throws {
        let invite = SharePlayInvite()
        let opened = try #require(SharePlayInvite(url: invite.url))
        #expect(opened == invite)
        #expect(opened.tag == invite.tag)
    }

    @Test("the link is short enough for a code a camera reads from across a car")
    func linkIsShort() {
        let link = SharePlayInvite().url.absoluteString
        #expect(link.hasPrefix("tracks://shareplay/"))
        // What a QR code of 29 by 29 squares holds, at its medium error correction.
        #expect(link.count <= 42)
    }

    @Test("every invite has its own key and tag")
    func invitesDiffer() {
        let first = SharePlayInvite()
        let second = SharePlayInvite()
        #expect(first.key.count == SharePlayInvite.keyLength)
        #expect(first.key != second.key)
        #expect(first.tag != second.tag)
    }

    @Test("the tag doesn't give the key away")
    func tagIsNotTheKey() {
        let invite = SharePlayInvite()
        #expect(invite.tag.count == 12)
        #expect(!invite.url.absoluteString.contains(invite.tag))
    }

    @Test("links that aren't a code open nothing", arguments: [
        "tracks://summary",
        "tracks://shareplay",
        "tracks://shareplay/",
        "tracks://shareplay/short",
        "tracks://shareplay/AAAAAAAAAAAAAAAAAAAAAA/more",
        "tracks://shareplay/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "https://shareplay/AAAAAAAAAAAAAAAAAAAAAA",
        "tracks://song/AAAAAAAAAAAAAAAAAAAAAA",
    ])
    func rejectsOtherLinks(_ link: String) throws {
        let url = try #require(URL(string: link))
        #expect(SharePlayInvite(url: url) == nil)
    }

    @Test("a code survives the camera's capitals in the scheme and host")
    func acceptsCapitalizedSchemeAndHost() throws {
        let invite = SharePlayInvite()
        let code = invite.url.lastPathComponent
        let url = try #require(URL(string: "TRACKS://SharePlay/\(code)"))
        #expect(SharePlayInvite(url: url) == invite)
    }

    @Test("the App Clip's link opens the same invite")
    func appClipLinkRoundTrips() throws {
        let invite = SharePlayInvite()
        let link = invite.appClipURL(bundleID: "com.luke.tracks.Clip")
        #expect(link.absoluteString.hasPrefix("https://appclip.apple.com/id?p=com.luke.tracks.Clip&c="))
        // What a QR code of 37 by 37 squares holds at its medium error correction.
        #expect(link.absoluteString.count <= 84)
        #expect(SharePlayInvite(url: link) == invite)
    }

    @Test("an App Clip link without a code opens nothing", arguments: [
        "https://appclip.apple.com/id?p=com.luke.tracks.Clip",
        "https://appclip.apple.com/id?p=com.luke.tracks.Clip&c=short",
        "https://example.com/id?p=com.luke.tracks.Clip&c=AAAAAAAAAAAAAAAAAAAAAA",
    ])
    func rejectsAppClipLinksWithoutCode(_ link: String) throws {
        #expect(SharePlayInvite(url: try #require(URL(string: link))) == nil)
    }

    @Test("a key of the wrong length makes no invite")
    func rejectsWrongKeyLength() {
        #expect(SharePlayInvite(key: Data(repeating: 1, count: 15)) == nil)
        #expect(SharePlayInvite(key: Data(repeating: 1, count: 32)) == nil)
        #expect(SharePlayInvite(key: Data(repeating: 1, count: 16)) != nil)
    }
}

/// Over this Mac's own loopback: the Mac keeps Bonjour's addresses from a test process,
/// which can't ask for Local Network, so each guest dials the host's port.
@Suite("SharePlay by code, over the network", .timeLimit(.minutes(1)))
@MainActor
struct SharePlayNearbyTests {
    /// A host listening, and a guest dialling it with a code.
    private func started(guestInvite: SharePlayInvite? = nil) async throws -> (SharePlayNearbyHost, SharePlayNearbyGuest) {
        let invite = SharePlayInvite()
        let host = SharePlayNearbyHost(invite: invite)
        host.start()
        try #require(await eventually { host.status == .ready && host.port != nil })
        let port = try #require(host.port)
        let guest = SharePlayNearbyGuest(invite: guestInvite ?? invite, dialing: .hostPort(host: "127.0.0.1", port: port))
        return (host, guest)
    }

    /// Checks every tenth of a second until something's true, up to a limit.
    private func eventually(within seconds: Double = 15, _ condition: () -> Bool) async -> Bool {
        let deadline = Date.now.addingTimeInterval(seconds)
        while Date.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    @Test("a guest with the code joins, says hello, and hears back")
    func guestJoinsAndHearsBack() async throws {
        let (host, guest) = try await started()
        defer {
            host.stop(sayingGoodbye: false)
            guest.stop()
        }
        var heardByHost: [SharePlayMessage] = []
        var heardByGuest: [SharePlayMessage] = []
        host.onMessage = { message, id in
            heardByHost.append(message)
            if message == .hello { host.send(.snapshot(SharePlaySnapshot(isPlaying: true)), to: id) }
        }
        guest.onMessage = { heardByGuest.append($0) }
        guest.start()

        try #require(await eventually { guest.status == .connected })
        #expect(guest.send(.hello))
        #expect(await eventually { host.guests.count == 1 })
        #expect(heardByHost == [.hello])
        #expect(await eventually { heardByGuest == [.snapshot(SharePlaySnapshot(isPlaying: true))] })
    }

    @Test("ending tells the guest")
    func endingTellsTheGuest() async throws {
        let (host, guest) = try await started()
        defer { guest.stop() }
        var heardByGuest: [SharePlayMessage] = []
        guest.onMessage = { heardByGuest.append($0) }
        guest.start()
        try #require(await eventually { guest.status == .connected })
        guest.send(.hello)
        try #require(await eventually { host.guests.count == 1 })

        host.stop(sayingGoodbye: true)
        #expect(await eventually { heardByGuest.contains(.ended) })
        #expect(await eventually { guest.status == .looking })
    }

    @Test("a guest leaving is counted out")
    func guestLeaving() async throws {
        let (host, guest) = try await started()
        defer { host.stop(sayingGoodbye: false) }
        var counts: [Int] = []
        host.onGuestsChanged = { counts.append($0.count) }
        guest.start()
        try #require(await eventually { guest.status == .connected })
        guest.send(.hello)
        try #require(await eventually { host.guests.count == 1 })

        guest.stop()
        #expect(await eventually { host.guests.isEmpty })
        #expect(counts == [1, 0])
    }

    @Test("an iPhone with another code never joins")
    func anotherCodeNeverJoins() async throws {
        let (host, stranger) = try await started(guestInvite: SharePlayInvite())
        defer {
            host.stop(sayingGoodbye: false)
            stranger.stop()
        }
        stranger.start()
        #expect(await eventually(within: 4) { stranger.status == .connected } == false)
        #expect(host.guests.isEmpty)
    }
}
