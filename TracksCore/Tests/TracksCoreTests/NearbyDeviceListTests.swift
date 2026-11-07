import Testing
import Foundation
@testable import TracksCore

@Suite("Your devices: what each is, which were seen lately, and how they stand")
struct NearbyDeviceListTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func device(_ id: String, seen secondsAgo: TimeInterval, song: String? = nil) -> KnownNearbyDevice {
        KnownNearbyDevice(id: id, name: "Device \(id)", platform: "Mac", kind: nil, lastSeen: now.addingTimeInterval(-secondsAgo), song: song, artist: nil)
    }

    @Test("a device's kind comes from what it says it is, and from its platform when it says nothing", arguments: [
        ("iPhone", nil, NearbyDeviceKind.iPhone),
        ("iPad", nil, .iPad),
        ("Mac", nil, .macBook),
        ("Mac", "iMac", .iMac),
        ("Mac", "Mac mini", .macMini),
        ("Mac", "Mac Pro", .macPro),
        ("Mac", "Mac", .macDesktop),
        ("Mac", "MacBook", .macBook),
        ("Vision", "something new", .iPhone),
    ] as [(String, String?, NearbyDeviceKind)])
    func kinds(platform: String, kind: String?, expected: NearbyDeviceKind) {
        #expect(NearbyDeviceKind(platform: platform, kind: kind) == expected)
    }

    @Test("a Mac tells what it is from its model and whether it has a battery", arguments: [
        ("MacBookPro18,3", true, NearbyDeviceKind.macBook),
        ("Mac14,2", true, .macBook),
        ("iMac21,1", false, .iMac),
        ("Macmini9,1", false, .macMini),
        ("MacPro7,1", false, .macPro),
        ("Mac14,13", false, .macDesktop),
    ])
    func localMac(model: String, hasBattery: Bool, expected: NearbyDeviceKind) {
        let kind = NearbyDeviceKind.mac(hardwareModel: model, hasBattery: hasBattery)
        #expect(kind == expected)
        // What it sends is read back as the same kind.
        #expect(NearbyDeviceKind(platform: "Mac", kind: kind.wireName) == expected)
    }

    @Test("every kind has a symbol of its own shape")
    func symbols() {
        let symbols = NearbyDeviceKind.allCases.map(\.symbol)
        #expect(Set(symbols).count == symbols.count)
    }

    @Test("seeing a device again replaces it, newest first, keeping no more than eight")
    func remembering() {
        var list: [KnownNearbyDevice] = (0..<8).map { device("\($0)", seen: TimeInterval($0) * 60) }
        list = KnownNearbyDevices.remembering(device("5", seen: 0, song: "Juno"), in: list)
        #expect(list.count == 8)
        #expect(list.first?.id == "5")
        #expect(list.first?.song == "Juno")
        #expect(list.filter { $0.id == "5" }.count == 1)

        list = KnownNearbyDevices.remembering(device("new", seen: 0), in: list)
        #expect(list.count == 8)
        #expect(list.first?.id == "new")
        // The one seen longest ago makes room.
        #expect(!list.contains { $0.id == "7" })
    }

    @Test("seeing a device again without a song keeps the last song it had")
    func keepsLastSong() {
        let list = [device("A", seen: 600, song: "Juno")]
        let again = KnownNearbyDevices.remembering(device("A", seen: 0), in: list)
        #expect(again.first?.song == "Juno")
        #expect(again.first?.lastSeen == now)
    }

    @Test("devices away are the ones not connected, seen within thirty days, latest first")
    func away() {
        let day: TimeInterval = 86_400
        let list = [device("here", seen: 0), device("yesterday", seen: day), device("lastWeek", seen: 7 * day), device("old", seen: 31 * day)]
        let away = KnownNearbyDevices.away(list, connected: ["here"], now: now)
        #expect(away.map(\.id) == ["yesterday", "lastWeek"])
    }

    @Test("the list survives being saved and read back, and anything unreadable reads as none")
    func storage() throws {
        let list = [device("A", seen: 60, song: "Juno"), device("B", seen: 120)]
        let data = try #require(KnownNearbyDevices.encoded(list))
        #expect(KnownNearbyDevices.decoded(data) == list)
        #expect(KnownNearbyDevices.decoded(Data("nonsense".utf8)).isEmpty)
        #expect(KnownNearbyDevices.decoded(nil).isEmpty)
    }

    @Test("the status says where things stand, in the order that matters")
    func status() {
        #expect(NearbyDevicesStatus(isOn: false, needsLocalNetwork: true, connected: 2, playingOn: "Mac") == .off)
        #expect(NearbyDevicesStatus(isOn: true, needsLocalNetwork: true, connected: 2, playingOn: "Mac") == .needsLocalNetwork)
        #expect(NearbyDevicesStatus(isOn: true, needsLocalNetwork: false, connected: 0, playingOn: nil) == .looking)
        #expect(NearbyDevicesStatus(isOn: true, needsLocalNetwork: false, connected: 2, playingOn: "Mac") == .playing(on: "Mac", nearby: 2))
        #expect(NearbyDevicesStatus(isOn: true, needsLocalNetwork: false, connected: 2, playingOn: nil) == .nearby(2))
    }

    @Test("the status reads as a line under the page's name and as a short value on its row", arguments: [
        (NearbyDevicesStatus.off, "Off", "Off"),
        (.needsLocalNetwork, "Local Network is off for Tracks", "Needs Local Network"),
        (.looking, "Looking for your devices nearby", "On"),
        (.nearby(1), "1 device nearby", "1 Nearby"),
        (.nearby(3), "3 devices nearby", "3 Nearby"),
        (.playing(on: "Luke's MacBook Pro", nearby: 1), "Playing on Luke's MacBook Pro", "1 Nearby"),
    ])
    func statusWords(status: NearbyDevicesStatus, line: String, short: String) {
        #expect(status.line == line)
        #expect(status.short == short)
    }

    @Test("when a device was last seen reads as people say it")
    func seenWords() {
        let locale = Locale(identifier: "en_US")
        #expect(KnownNearbyDevices.seen(now.addingTimeInterval(-20), now: now, locale: locale) == "Seen just now")
        #expect(KnownNearbyDevices.seen(now.addingTimeInterval(-2 * 3_600), now: now, locale: locale) == "Seen 2 hours ago")
        #expect(KnownNearbyDevices.seen(now.addingTimeInterval(-86_400), now: now, locale: locale) == "Seen yesterday")
    }
}

@Suite("Where the music is, among your devices")
struct MusicLocationTests {
    let macPlaying = MusicLocation.Peer(id: "mac", hasSong: true, isPlaying: true)
    let iPadPaused = MusicLocation.Peer(id: "ipad", hasSong: true, isPlaying: false)
    let miniIdle = MusicLocation.Peer(id: "mini", hasSong: false, isPlaying: false)

    @Test("the device controlled from here leads while it has a song, and not after")
    func controlled() {
        #expect(MusicLocation(controlled: "ipad", isPlayingHere: true, hasSongHere: true, peers: [macPlaying, iPadPaused]) == .device("ipad"))
        #expect(MusicLocation(controlled: "mini", isPlayingHere: true, hasSongHere: true, peers: [miniIdle]) == .here)
    }

    @Test("music playing beats a song held paused, here before elsewhere")
    func playingFirst() {
        #expect(MusicLocation(controlled: nil, isPlayingHere: true, hasSongHere: true, peers: [macPlaying]) == .here)
        #expect(MusicLocation(controlled: nil, isPlayingHere: false, hasSongHere: true, peers: [iPadPaused, macPlaying]) == .device("mac"))
        #expect(MusicLocation(controlled: nil, isPlayingHere: false, hasSongHere: true, peers: [iPadPaused]) == .here)
        #expect(MusicLocation(controlled: nil, isPlayingHere: false, hasSongHere: false, peers: [miniIdle, iPadPaused]) == .device("ipad"))
        #expect(MusicLocation(controlled: nil, isPlayingHere: false, hasSongHere: false, peers: [miniIdle]) == .nowhere)
    }
}
