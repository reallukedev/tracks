import Testing
@testable import TracksCore

@Suite("Speakers: Music's AirPlay devices on the Mac, and the iPhone's audio route")
struct SpeakersTests {
    private func line(_ kind: String, _ name: String, available: Bool = true, audio: Bool = true, selected: Bool = false, volume: String = "50") -> String {
        ["device", kind, "\(available)", "\(audio)", "\(selected)", volume, name].joined(separator: "\t")
    }

    @Test("Music's answer is read into the speakers it can play to, in its menu's order")
    func parsesAndOrders() {
        let output = [
            "state\tplaying",
            line("Apple TV", "Living Room"),
            line("HomePod", "Kitchen", selected: true, volume: "35"),
            line("computer", "MacBook Pro", selected: true, volume: "missing value"),
            line("HomePod", "Bedroom 10"),
            line("HomePod", "Bedroom 2"),
            line("AirPlay device", "Garden", available: false),
            line("Apple TV", "Den Screen", audio: false),
            line("Bluetooth device", "AirPods"),
            line("something new", "Studio"),
            "garbage without tabs",
            "",
        ].joined(separator: "\n")
        let speakers = MusicSpeakers.parse(output)
        #expect(speakers.state == .playing)
        #expect(speakers.speakers.map(\.name) == ["MacBook Pro", "Bedroom 2", "Bedroom 10", "Kitchen", "Studio", "Living Room", "AirPods"])
        #expect(speakers.speakers.map(\.kind) == [.computer, .homePod, .homePod, .homePod, .speaker, .appleTV, .bluetooth])
        let kitchen = speakers.speakers.first { $0.name == "Kitchen" }
        #expect(kitchen?.isSelected == true)
        #expect(kitchen?.volume == 35)
        #expect(speakers.speakers.first?.volume == nil)
        #expect(speakers.hasSpeakers)
        #expect(speakers.hasScreens)
        #expect(speakers.destinationNames == ["MacBook Pro", "Kitchen"])
    }

    @Test("a name keeps a tab inside it, a repeated name keeps its first line, and volumes stay in range")
    func oddValues() {
        let output = [
            line("HomePod", "Kitchen\tUpstairs", volume: "140"),
            line("HomePod", "Kitchen\tUpstairs", selected: true, volume: "10"),
            line("HomePod", "Hall", volume: "-5"),
        ].joined(separator: "\r\n")
        let speakers = MusicSpeakers.parse(output)
        #expect(speakers.state == .stopped)
        #expect(speakers.speakers.map(\.name) == ["Hall", "Kitchen\tUpstairs"])
        #expect(speakers.speakers.map(\.volume) == [0, 100])
        #expect(speakers.speakers.allSatisfy { !$0.isSelected })
        #expect(speakers.destinationNames == nil)
    }

    @Test("nothing besides the Mac means nowhere to send the music")
    func onlyTheMac() {
        let speakers = MusicSpeakers.parse(["state\tpaused", line("computer", "Mac Studio", selected: true)].joined(separator: "\n"))
        #expect(speakers.state == .paused)
        #expect(!speakers.hasSpeakers)
        #expect(speakers.destinationNames == nil)
        #expect(MusicSpeakers.parse("").speakers.isEmpty)
    }

    @Test("choosing one plays there alone; toggling groups rooms but never leaves the music nowhere")
    func choosing() {
        let start = MusicSpeakers(state: .playing, speakers: [
            AirPlaySpeaker(name: "Mac", kind: .computer, isSelected: true, volume: 80),
            AirPlaySpeaker(name: "Kitchen", kind: .homePod, isSelected: false, volume: 30),
            AirPlaySpeaker(name: "Office", kind: .homePod, isSelected: false, volume: 30),
        ])
        let kitchen = start.choosingOnly("Kitchen")
        #expect(kitchen.destinationNames == ["Kitchen"])

        let group = kitchen.toggling("Office")
        #expect(group.destinationNames == ["Kitchen", "Office"])

        let alone = group.toggling("Kitchen").toggling("Office")
        #expect(alone.destinationNames == ["Office"], "the last room playing stays on")

        #expect(start.choosingOnly("Garden") == start)
        #expect(start.toggling("Garden") == start)
        #expect(start.setting("Kitchen", volume: 250).speakers[1].volume == 100)
    }

    @Test("the iPhone's route names where the music goes, AirPlay first, and nothing for its own speaker", arguments: [
        ([("Speaker", "Speaker")], nil),
        ([("Receiver", "Receiver")], nil),
        ([("AirPlay", "Kitchen")], SpeakerRoute(kind: .airPlay, names: ["Kitchen"])),
        ([("AirPlay", "Kitchen"), ("AirPlay", "Living Room"), ("AirPlay", "Kitchen")], SpeakerRoute(kind: .airPlay, names: ["Kitchen", "Living Room"])),
        ([("Speaker", "Speaker"), ("AirPlay", "Kitchen")], SpeakerRoute(kind: .airPlay, names: ["Kitchen"])),
        ([("BluetoothA2DPOutput", "AirPods Pro")], SpeakerRoute(kind: .bluetooth, names: ["AirPods Pro"])),
        ([("CarAudio", "CarPlay")], SpeakerRoute(kind: .car, names: ["CarPlay"])),
        ([("AirPlay", "  ")], nil),
    ] as [([(String, String)], SpeakerRoute?)])
    func iPhoneRoute(outputs: [(String, String)], expected: SpeakerRoute?) {
        #expect(SpeakerRoute(outputs: outputs.map { (type: $0.0, name: $0.1) }) == expected)
    }
}
