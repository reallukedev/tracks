import Testing
import Foundation
@testable import TracksCore

@Suite("Backdrop clock")
struct BackdropClockTests {
    @Test("Starts at its speed, with no ramp")
    func startsAtSpeed() {
        let clock = BackdropClock(speed: 1, at: 100, phase: 5)
        #expect(clock.phase(at: 100) == 5)
        #expect(abs(clock.phase(at: 102) - 7) < 1e-9)
        #expect(clock.speed(at: 150) == 1)
    }

    @Test("A pause glides to a stop, and it rests where it stopped")
    func pauseGlides() {
        var clock = BackdropClock(speed: 1, at: 0, easing: 0.7)
        clock.setSpeed(0, at: 10)
        // Still moving just after, slower a moment later, stopped a few seconds on.
        #expect(abs(clock.speed(at: 10) - 1) < 1e-9)
        #expect(clock.speed(at: 10.7) < 0.4)
        #expect(!clock.isAtRest(at: 10.5))
        #expect(clock.isAtRest(at: 16))
        // It travels on by the easing's worth, 0.7 seconds of phase, and no further.
        let resting = clock.phase(at: 60)
        #expect(abs(resting - 10.7) < 1e-6)
        #expect(clock.phase(at: 120) == resting)
    }

    @Test("Playing again picks up from where it rested, without a jump")
    func resumesWithoutJump() {
        var clock = BackdropClock(speed: 1, at: 0)
        clock.setSpeed(0, at: 10)
        let rested = clock.phase(at: 30)
        clock.setSpeed(1, at: 30)
        #expect(abs(clock.phase(at: 30) - rested) < 1e-9)
        #expect(clock.speed(at: 30) < 0.01)
        #expect(clock.speed(at: 35) > 0.99)
    }

    @Test("Phase and speed are continuous across changes mid-ease", arguments: [0.1, 0.5, 2.0])
    func continuousMidEase(gap: Double) {
        var clock = BackdropClock(speed: 1, at: 0)
        clock.setSpeed(0, at: 5)
        let before = (clock.phase(at: 5 + gap), clock.speed(at: 5 + gap))
        clock.setSpeed(1.4, at: 5 + gap)
        #expect(abs(clock.phase(at: 5 + gap) - before.0) < 1e-9)
        #expect(abs(clock.speed(at: 5 + gap) - before.1) < 1e-9)
    }

    @Test("Says how long until it rests, only once it's stopping")
    func secondsToRest() throws {
        var clock = BackdropClock(speed: 1, at: 0)
        #expect(clock.secondsToRest(from: 0) == nil)
        clock.setSpeed(0, at: 2)
        let wait = try #require(clock.secondsToRest(from: 2))
        #expect(wait > 1 && wait < 6)
        #expect(clock.isAtRest(at: 2 + wait + 0.01))
        #expect(clock.secondsToRest(from: 2 + wait + 1) == 0)
    }
}

@Suite("Cover palette")
struct CoverPaletteTests {
    typealias Colour = CoverPalette.Colour

    /// Pixels of these colours, in these numbers, fully opaque.
    func pixels(_ parts: [(Colour, Int)], alpha: UInt8 = 255) -> [UInt8] {
        parts.flatMap { colour, count in
            [[UInt8]](repeating: [
                UInt8((colour.red * 255).rounded()),
                UInt8((colour.green * 255).rounded()),
                UInt8((colour.blue * 255).rounded()),
                alpha,
            ], count: count).flatMap(\.self)
        }
    }

    let red = Colour(red: 0.85, green: 0.1, blue: 0.1)
    let blue = Colour(red: 0.1, green: 0.2, blue: 0.85)
    let grey = Colour(red: 0.5, green: 0.5, blue: 0.5)

    @Test("A cover of two colours gives both, the larger first")
    func twoColours() throws {
        let found = CoverPalette.colours(rgba: pixels([(blue, 60), (red, 40)]))
        try #require(found.count == 2)
        #expect(found[0].distance(to: blue) < 0.02)
        #expect(found[1].distance(to: red) < 0.02)
    }

    @Test("A small vivid shape on grey still counts")
    func vividShapeOnGrey() {
        let found = CoverPalette.colours(rgba: pixels([(grey, 90), (red, 10)]))
        #expect(found.contains { $0.distance(to: red) < 0.02 })
        #expect(found.contains { $0.distance(to: grey) < 0.02 })
    }

    @Test("Shades too close together are one colour")
    func closeShadesMerge() {
        let nearRed = Colour(red: 0.8, green: 0.14, blue: 0.1)
        let found = CoverPalette.colours(rgba: pixels([(red, 50), (nearRed, 50)]))
        #expect(found.count == 1)
    }

    @Test("Specks are left out")
    func specksLeftOut() {
        let found = CoverPalette.colours(rgba: pixels([(blue, 990), (red, 10)]))
        #expect(found.count == 1)
    }

    @Test("Clear pixels are left out, and a clear cover has no colours")
    func clearPixels() {
        #expect(CoverPalette.colours(rgba: pixels([(red, 20)], alpha: 0)).isEmpty)
        #expect(CoverPalette.colours(rgba: []).isEmpty)
    }

    @Test("Never more than asked for")
    func limit() {
        let hues = (0..<8).map { index in
            (Colour(red: index.isMultiple(of: 2) ? 0.9 : 0.1, green: Double(index) / 8, blue: 1 - Double(index) / 8), 10)
        }
        #expect(CoverPalette.colours(rgba: pixels(hues), limit: 3).count == 3)
    }

    @Test("Filling out a one-colour cover adds lighter and darker shades of it")
    func filled() throws {
        let filled = CoverPalette.filled([red], to: 4)
        try #require(filled.count == 4)
        #expect(filled[0] == red)
        #expect(filled[1].brightness > red.brightness || filled[1].chroma < red.chroma)
        #expect(filled[2].brightness < red.brightness)
        #expect(CoverPalette.filled([], to: 4).isEmpty)
        #expect(CoverPalette.filled([red, blue, grey, red, blue], to: 3).count == 5)
    }
}
