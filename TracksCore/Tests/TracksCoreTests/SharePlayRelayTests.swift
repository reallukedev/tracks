import Testing
import Foundation
@testable import TracksCore

@Suite("SharePlay's relay")
struct SharePlayRelayTests {
    private let snapshot = SharePlayMessage.snapshot(SharePlaySnapshot(
        nowPlaying: SharePlayTrack(id: "q1", title: "Juno", artistName: "Sabrina Carpenter"),
        isPlaying: true
    ))

    @Test("a sealed message opens with the same code")
    func sealedMessageOpens() throws {
        let invite = SharePlayInvite()
        let box = try #require(SharePlayRelayBox(invite: invite).seal(snapshot))
        #expect(SharePlayRelayBox(invite: invite).open(box) == snapshot)
    }

    @Test("the relay can't read a box, and another code can't open it")
    func anotherCodeCantOpen() throws {
        let box = try #require(SharePlayRelayBox(invite: SharePlayInvite()).seal(snapshot))
        #expect(SharePlayRelayBox(invite: SharePlayInvite()).open(box) == nil)
        let opened = try #require(Data(base64Encoded: box))
        #expect(String(data: opened, encoding: .utf8)?.contains("Juno") != true)
    }

    @Test("anything that isn't a box opens as nothing", arguments: ["", "not base64!", "AAAA", Data(repeating: 1, count: 64).base64EncodedString()])
    func junkOpensAsNothing(_ junk: String) {
        #expect(SharePlayRelayBox(invite: SharePlayInvite()).open(junk) == nil)
    }

    @Test("the same message seals differently each time")
    func sealsAreFresh() throws {
        let box = SharePlayRelayBox(invite: SharePlayInvite())
        #expect(try #require(box.seal(.hello)) != box.seal(.hello))
    }

    @Test("a channel is named by the code's tag, never its key")
    func topicUsesTag() {
        let invite = SharePlayInvite()
        let topic = SharePlayRelayConfig.topic(for: invite)
        #expect(topic == "realtime:motif-shareplay-\(invite.tag)")
        #expect(!topic.contains(invite.url.lastPathComponent))
    }

    @Test("no relay without both its host and key", arguments: [
        (nil, "key"), ("host.supabase.co", nil), ("", "key"), ("host.supabase.co", ""), ("$(TRACKS_RELAY_HOST)", "key"),
    ] as [(String?, String?)])
    func configNeedsBoth(host: String?, key: String?) {
        #expect(SharePlayRelayConfig(host: host, key: key) == nil)
    }

    @Test("the socket's address carries the key and the protocol version")
    func socketURL() throws {
        let config = try #require(SharePlayRelayConfig(host: "abc.supabase.co", key: "sb_publishable_x"))
        #expect(config.socketURL?.absoluteString == "wss://abc.supabase.co/realtime/v1/websocket?apikey=sb_publishable_x&vsn=1.0.0")
    }
}

@Suite("Who's on a relay channel")
struct SharePlayRelayPresenceTests {
    private func entry(_ refs: String...) -> [String: Any] {
        ["metas": refs.map { ["phx_ref": $0] }]
    }

    @Test("the state on joining, then joins and leaves")
    func stateThenDiffs() {
        var presence = SharePlayRelayPresence()
        presence.replace(with: ["host": entry("a")])
        #expect(presence.keys == ["host"])
        presence.apply(joins: ["guest": entry("b")], leaves: [:])
        #expect(presence.keys == ["host", "guest"])
        presence.apply(joins: [:], leaves: ["guest": entry("b")])
        #expect(presence.keys == ["host"])
    }

    @Test("someone connected twice stays until both connections leave")
    func twoConnections() {
        var presence = SharePlayRelayPresence()
        presence.apply(joins: ["guest": entry("old")], leaves: [:])
        presence.apply(joins: ["guest": entry("new")], leaves: [:])
        presence.apply(joins: [:], leaves: ["guest": entry("old")])
        #expect(presence.keys == ["guest"])
        presence.apply(joins: [:], leaves: ["guest": entry("new")])
        #expect(presence.keys.isEmpty)
    }

    @Test("a fresh state replaces what was known")
    func stateReplaces() {
        var presence = SharePlayRelayPresence()
        presence.apply(joins: ["gone": entry("x")], leaves: [:])
        presence.replace(with: ["host": entry("y")])
        #expect(presence.keys == ["host"])
    }
}

/// Over the real relay: set TRACKS_RELAY_HOST and TRACKS_RELAY_KEY to run.
@Suite("SharePlay over the real relay", .timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["TRACKS_RELAY_KEY"] != nil))
@MainActor
struct SharePlayRelayLiveTests {
    private func eventually(within seconds: Double = 20, _ condition: () -> Bool) async -> Bool {
        let deadline = Date.now.addingTimeInterval(seconds)
        while Date.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    @Test("a guest joins, hears what's on, adds a song, and hears it end")
    func roundTrip() async throws {
        let environment = ProcessInfo.processInfo.environment
        let config = try #require(SharePlayRelayConfig(host: environment["TRACKS_RELAY_HOST"], key: environment["TRACKS_RELAY_KEY"]))
        let invite = SharePlayInvite()
        let host = SharePlayRelayHost(invite: invite, config: config)
        let guest = SharePlayRelayGuest(invite: invite, config: config)
        defer { guest.stop() }
        var heardByGuest: [SharePlayMessage] = []
        host.onMessage = { message, id in
            switch message {
            case .hello: host.send(.snapshot(SharePlaySnapshot(isPlaying: true)), to: id)
            case .add(let request): host.send(.reply(SharePlayAddReply(requestID: request.id, outcome: .added(.next))), to: id)
            default: break
            }
        }
        guest.onMessage = { heardByGuest.append($0) }
        host.start()
        try #require(await eventually { host.status == .ready })
        guest.start()
        try #require(await eventually { guest.status == .connected })
        #expect(guest.send(.hello))
        #expect(await eventually { heardByGuest.contains(.snapshot(SharePlaySnapshot(isPlaying: true))) })
        #expect(host.guests == [guest.id])

        let request = SharePlayAddRequest(song: SharePlaySong(catalogID: "1", title: "Juno", artistName: "Sabrina Carpenter"), placement: .next)
        #expect(guest.send(.add(request)))
        #expect(await eventually { heardByGuest.contains(.reply(SharePlayAddReply(requestID: request.id, outcome: .added(.next)))) })

        host.stop(sayingGoodbye: true)
        #expect(await eventually { heardByGuest.contains(.ended) })
        #expect(await eventually { guest.status == .looking })
    }
}

@Suite("Whether a code can be joined")
@MainActor
struct SharePlayCodeHostStatusTests {
    @Test("either way working is enough, and with neither, what's wrong nearby is said", arguments: [
        (SharePlayNearbyHost.Status.ready, nil, SharePlayCodeHost.Status.ready),
        (.needsLocalNetwork, .ready, .ready),
        (.failed, .ready, .ready),
        (.needsLocalNetwork, .starting, .needsLocalNetwork),
        (.needsLocalNetwork, nil, .needsLocalNetwork),
        (.failed, .starting, .failed),
        (.starting, .starting, .starting),
        (.starting, nil, .starting),
    ] as [(SharePlayNearbyHost.Status, SharePlayRelayHost.Status?, SharePlayCodeHost.Status)])
    func status(nearby: SharePlayNearbyHost.Status, relay: SharePlayRelayHost.Status?, expected: SharePlayCodeHost.Status) {
        #expect(SharePlayCodeHost.status(nearby: nearby, relay: relay) == expected)
    }
}
