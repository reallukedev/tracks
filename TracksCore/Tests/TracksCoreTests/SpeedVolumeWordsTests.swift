import Testing
import Foundation
@testable import TracksCore

@Suite("Louder at Speed's words")
struct SpeedVolumeWordsTests {
    @Test("off, the status line says what it would do and the row says Off")
    func off() {
        let standing = SpeedVolumeStanding(isOn: false, location: .notAsked)
        let status = SpeedVolumeWords.status(standing)
        #expect(status.tone == .plain)
        #expect(status.line.contains("highway"))
        #expect(SpeedVolumeWords.rowValue(standing) == "Off")
        #expect(standing.blocker == nil, "nothing is in the way of a feature that's off")
    }

    @Test("on and ready, it says when it starts, and the row names the amount")
    func ready() {
        let standing = SpeedVolumeStanding(isOn: true, amount: .strong, location: .always)
        #expect(SpeedVolumeWords.status(standing).line == "On · starts when you drive")
        #expect(SpeedVolumeWords.rowValue(standing) == "Strong")
    }

    @Test("following a drive, it says so in the status line and the row")
    func following() {
        let standing = SpeedVolumeStanding(isOn: true, location: .whileUsing, isFollowing: true)
        #expect(SpeedVolumeWords.status(standing).line == "On · following your speed now")
        #expect(SpeedVolumeWords.rowValue(standing) == "Driving")
    }

    @Test("each problem with Location needs you, and says the next thing to do", arguments: [
        (SpeedVolumeStanding.Location.notAsked, SpeedVolumeStanding.Blocker.needsLocation),
        (.off, .locationOff),
        (.restricted, .locationRestricted),
    ])
    func locationProblems(location: SpeedVolumeStanding.Location, blocker: SpeedVolumeStanding.Blocker) {
        let standing = SpeedVolumeStanding(isOn: true, location: location)
        #expect(standing.blocker == blocker)
        #expect(SpeedVolumeWords.status(standing).tone == .attention)
        #expect(SpeedVolumeWords.rowValue(standing) == "Needs Location")
    }

    @Test("Approximate Location is a problem only once Location is allowed")
    func precise() {
        let approximate = SpeedVolumeStanding(isOn: true, location: .whileUsing, isPrecise: false)
        #expect(approximate.blocker == .needsPreciseLocation)
        #expect(SpeedVolumeWords.rowValue(approximate) == "Needs Precise Location")
        #expect(SpeedVolumeWords.accessFooter(approximate).contains("Precise Location"))
        let off = SpeedVolumeStanding(isOn: true, location: .off, isPrecise: false)
        #expect(off.blocker == .locationOff)
    }

    @Test("Apple Music over CarPlay is the car's to set, said plainly and not as a fault")
    func appleMusicOnCarPlay() {
        let standing = SpeedVolumeStanding(isOn: true, location: .always, isAppleMusic: true, isOnCarPlay: true)
        #expect(standing.blocker == .carSetsVolume)
        #expect(SpeedVolumeWords.status(standing).tone == .plain)
        #expect(SpeedVolumeWords.switchFooter(standing).contains("Your Music"))
        // Your own music on CarPlay has nothing in its way.
        let yours = SpeedVolumeStanding(isOn: true, location: .always, isOnCarPlay: true)
        #expect(yours.blocker == nil)
    }

    @Test("the switch's footer explains what each player does with your volume")
    func switchFooters() {
        let yours = SpeedVolumeWords.switchFooter(SpeedVolumeStanding(isOn: true, location: .always))
        let appleMusic = SpeedVolumeWords.switchFooter(SpeedVolumeStanding(isOn: true, location: .always, isAppleMusic: true))
        #expect(yours.contains("volume buttons"))
        #expect(appleMusic.contains("iPhone’s volume"))
        #expect(yours != appleMusic)
    }

    @Test("the access footer says where it starts, and always where your location goes")
    func accessFooters() {
        let whileUsing = SpeedVolumeWords.accessFooter(SpeedVolumeStanding(isOn: true, location: .whileUsing))
        #expect(whileUsing.contains("CarPlay"))
        #expect(whileUsing.contains("Always"))
        let always = SpeedVolumeWords.accessFooter(SpeedVolumeStanding(isOn: true, location: .always))
        #expect(!always.contains("Change to Always"))
        let noMotion = SpeedVolumeWords.accessFooter(SpeedVolumeStanding(isOn: true, location: .always, motion: .off))
        #expect(noMotion.contains("only CarPlay counts"))
        for footer in [whileUsing, always, noMotion] {
            #expect(footer.hasSuffix("never leaves this iPhone."))
        }
    }

    @Test("the amount's footer gives its level in the units of the road you drive on")
    func amountFooters() {
        #expect(SpeedVolumeWords.amountFooter(.moderate, usesMiles: true).contains("8 dB"))
        #expect(SpeedVolumeWords.amountFooter(.moderate, usesMiles: true).contains("70 mph"))
        #expect(SpeedVolumeWords.amountFooter(.slight, usesMiles: false).contains("110 km/h"))
        #expect(Set(SpeedVolumeAmount.allCases.map(SpeedVolumeWords.amountDetail)).count == 3)
    }

    @Test("the access rows use Settings' own words, and no row for motion there isn't")
    func accessValues() {
        #expect(SpeedVolumeWords.locationValue(.whileUsing) == "While Using")
        #expect(SpeedVolumeWords.locationValue(.always) == "Always")
        #expect(SpeedVolumeWords.motionValue(.off) == "Off")
        #expect(SpeedVolumeWords.motionValue(.unavailable) == nil)
    }

    @Test("a level reads as how much quieter than your volume it is")
    func levels() {
        #expect(SpeedVolumeWords.levelPhrase(0) == "At your volume")
        #expect(SpeedVolumeWords.levelPhrase(-0.3) == "At your volume")
        #expect(SpeedVolumeWords.levelPhrase(-7.6) == "About 8 dB quieter")
    }

    @Test("nothing Louder at Speed says uses an em dash")
    func noDashes() {
        var lines: [String] = []
        for isOn in [false, true] {
            for location in [SpeedVolumeStanding.Location.notAsked, .whileUsing, .always, .off, .restricted] {
                for isAppleMusic in [false, true] {
                    let standing = SpeedVolumeStanding(isOn: isOn, location: location, isAppleMusic: isAppleMusic, isOnCarPlay: isAppleMusic)
                    lines += [SpeedVolumeWords.status(standing).line, SpeedVolumeWords.rowValue(standing), SpeedVolumeWords.switchFooter(standing), SpeedVolumeWords.accessFooter(standing)]
                }
            }
        }
        #expect(lines.allSatisfy { !$0.contains("\u{2014}") })
    }
}
