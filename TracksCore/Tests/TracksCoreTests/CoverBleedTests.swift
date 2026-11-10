import Testing
import Foundation
import CoreGraphics
@testable import TracksCore

/// A cover `side` square, each pixel coloured by `paint(x, y)` (0 to 255 each), opaque
/// unless `paint` gives an alpha.
private func cover(side: Int = 48, _ paint: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> [UInt8] {
    var rgba: [UInt8] = []
    rgba.reserveCapacity(side * side * 4)
    for y in 0..<side {
        for x in 0..<side {
            let (r, g, b, a) = paint(x, y)
            // Premultiplied, as a bitmap context stores it.
            let scale = Double(a) / 255
            rgba += [UInt8(Double(r) * scale), UInt8(Double(g) * scale), UInt8(Double(b) * scale), a]
        }
    }
    return rgba
}

private func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> [UInt8] {
    cover { _, _ in (r, g, b, 255) }
}

private func distance(_ a: CoverBleed.Colour, _ b: CoverBleed.Colour) -> Double {
    sqrt(pow(a.red - b.red, 2) + pow(a.green - b.green, 2) + pow(a.blue - b.blue, 2))
}

@Suite("Full Cover's edges")
struct CoverBleedTests {
    @Test("Each edge carries its own colour, so the cover simply goes on")
    func edgesKeepTheirColours() throws {
        // Sky above, grass below, a wall on each side.
        let pixels = cover { x, y in
            if x < 3 { return (200, 40, 40, 255) }
            if x > 44 { return (40, 40, 200, 255) }
            return y < 24 ? (90, 170, 230, 255) : (30, 140, 60, 255)
        }
        let bleed = try #require(CoverBleed(rgba: pixels, side: 48))
        let grass = CoverBleed.Colour(red: 30 / 255, green: 140 / 255, blue: 60 / 255)
        let sky = CoverBleed.Colour(red: 90 / 255, green: 170 / 255, blue: 230 / 255)
        // The middle of the bottom edge is grass, the middle of the top sky.
        #expect(distance(bleed.bottom[6], grass) < 0.03, "\(bleed.bottom.map { ($0.red, $0.green, $0.blue) })")
        #expect(distance(bleed.top[6], sky) < 0.03)
        // A side is read from the side's band, not the middle.
        #expect(bleed.leading.allSatisfy { $0.red > $0.blue })
        #expect(bleed.trailing.allSatisfy { $0.blue > $0.red })
    }

    @Test("The type is dark on a light edge and white on a dark or mid one", arguments: [
        (rgb: (255, 255, 255), ink: CoverBleed.Ink.dark),
        (rgb: (230, 200, 60), ink: .dark),
        (rgb: (150, 175, 190), ink: .dark),
        (rgb: (0, 0, 0), ink: .light),
        (rgb: (60, 160, 70), ink: .light),
        (rgb: (200, 30, 40), ink: .light),
    ] as [(rgb: (Int, Int, Int), ink: CoverBleed.Ink)])
    func inkFollowsTheEdge(_ example: (rgb: (Int, Int, Int), ink: CoverBleed.Ink)) throws {
        let (r, g, b) = example.rgb
        let bleed = try #require(CoverBleed(rgba: solid(UInt8(r), UInt8(g), UInt8(b)), side: 48))
        #expect(bleed.ink(.bottom) == example.ink)
    }

    @Test("Whatever the cover, the type on its colours reads", arguments: [false, true])
    func typeAlwaysReads(increasedContrast: Bool) throws {
        // A sweep of colours, light, dark and in between, of every hue.
        for r in stride(from: 0, through: 255, by: 51) {
            for g in stride(from: 0, through: 255, by: 51) {
                for b in stride(from: 0, through: 255, by: 51) {
                    let bleed = try #require(CoverBleed(rgba: solid(UInt8(r), UInt8(g), UInt8(b)), side: 16))
                    let ink: CoverBleed.Colour = bleed.ink(.bottom) == .dark ? .black : .white
                    let least = bleed.ink(.bottom) == .dark ? (increasedContrast ? 10.0 : 7.0) : (increasedContrast ? 7.0 : 4.5)
                    let floor = bleed.floor(.bottom, increasedContrast: increasedContrast)
                    #expect(floor.contrast(with: ink) >= least - 0.05, "rgb(\(r), \(g), \(b))")
                    for stop in bleed.legible(.bottom, increasedContrast: increasedContrast) {
                        #expect(stop.contrast(with: ink) >= least - 0.05, "rgb(\(r), \(g), \(b))")
                    }
                }
            }
        }
    }

    @Test("A colour that already reads is left as it is")
    func readableColoursUntouched() throws {
        let navy = try #require(CoverBleed(rgba: solid(10, 20, 60), side: 16))
        let colour = try #require(navy.bottom.first)
        #expect(distance(navy.floor(.bottom), colour) < 0.005)
    }

    @Test("Settles into the colour most of the edge is, not a muddy mix")
    func floorIsTheDominantColour() throws {
        // Three quarters of the bottom is a blue sky, a quarter a warm shoulder.
        let pixels = cover { x, _ in x < 36 ? (40, 90, 200, 255) : (220, 160, 120, 255) }
        let bleed = try #require(CoverBleed(rgba: pixels, side: 48))
        let floor = bleed.average(.bottom)
        #expect(floor.blue > floor.red)
        #expect(floor.blue > 0.5)
    }

    @Test("A busy edge is calmed, a plain one kept")
    func busyEdgesAreCalmed() throws {
        // Black and white stripes, two pixels wide: lettering, or a crowd.
        let stripes = try #require(CoverBleed(rgba: cover { x, _ in x / 2 % 2 == 0 ? (0, 0, 0, 255) : (255, 255, 255, 255) }, side: 48))
        let lightness = stripes.bottom.map(\.luminance)
        #expect((lightness.max() ?? 0) - (lightness.min() ?? 0) < 0.15)
        // A gentle gradient keeps its run from end to end.
        let gradient = try #require(CoverBleed(rgba: cover { x, _ in (UInt8(x * 5), UInt8(x * 5), UInt8(x * 5), 255) }, side: 48))
        #expect(gradient.bottom.last!.luminance - gradient.bottom.first!.luminance > 0.3)
    }

    @Test("See-through parts of a cover take their neighbours' colour, not black")
    func transparencyIgnored() throws {
        let pixels = cover { x, _ in x < 24 ? (0, 0, 0, 0) : (240, 200, 40, 255) }
        let bleed = try #require(CoverBleed(rgba: pixels, side: 48))
        #expect(bleed.bottom.allSatisfy { $0.red > 0.6 && $0.green > 0.5 })
        // Wholly see-through: nothing to read.
        #expect(CoverBleed(rgba: cover { _, _ in (0, 0, 0, 0) }, side: 48) == nil)
    }
}

@Suite("Full Cover's layout and field")
struct CoverBleedFieldTests {
    let phone = CGSize(width: 402, height: 874)

    @Test("Under the song, the cover is the screen's width, top never cut, foot cut short when room is")
    func belowFollowsTheRoom() {
        // Room for all of it.
        let roomy = CGRect(x: 0, y: 90, width: 402, height: 402)
        #expect(CoverBleedLayout.frame(in: phone, focus: roomy, direction: .below) == roomy)
        #expect(CoverBleedLayout.shownFrame(of: roomy, focus: roomy) == roomy)
        // A little short: still full width from the room's top, its foot shown only a little
        // past the room.
        let short = CGRect(x: 0, y: 90, width: 402, height: 355)
        let cover = CoverBleedLayout.frame(in: phone, focus: short, direction: .below)
        #expect(cover == CGRect(x: 0, y: 90, width: 402, height: 402))
        let shown = CoverBleedLayout.shownFrame(of: cover, focus: short)
        #expect(shown.minY == 90 && shown.width == 402)
        #expect(shown.maxY > short.maxY && shown.maxY < short.maxY + 12)
        // Far too short, at the largest text: whole, at the room's height.
        let tiny = CGRect(x: 0, y: 90, width: 402, height: 200)
        #expect(CoverBleedLayout.frame(in: phone, focus: tiny, direction: .below) == CGRect(x: 101, y: 90, width: 200, height: 200))
    }

    @Test("Under the song, a cover rises under the top bar rather than lose its foot, if its subject stays clear")
    func risesBySubject() {
        // A figure low on a sea: up by all that was cut short.
        #expect(CoverBleedLayout.rise(subject: CGRect(x: 0.4, y: 0.55, width: 0.2, height: 0.2), side: 402, top: 83, ceiling: 111, cutShort: 39) == 39)
        // Never past the screen's top.
        #expect(CoverBleedLayout.rise(subject: nil, side: 402, top: 20, ceiling: 48, cutShort: 39) == 20)
        // A title across the top: stays where it is.
        #expect(CoverBleedLayout.rise(subject: CGRect(x: 0.2, y: 0.08, width: 0.6, height: 0.8), side: 402, top: 83, ceiling: 111, cutShort: 39) == 0)
        // In between: just far enough that the subject's top sits 12 points under the bar.
        let partway = CoverBleedLayout.rise(subject: CGRect(x: 0.3, y: 0.11, width: 0.4, height: 0.6), side: 402, top: 83, ceiling: 111, cutShort: 39)
        #expect(partway > 0 && partway < 39)
        #expect(abs((83 - partway) + 0.11 * 402 - (111 + 12)) < 0.001)
        // Nothing cut short: nowhere to go.
        #expect(CoverBleedLayout.rise(subject: nil, side: 402, top: 83, ceiling: 111, cutShort: 0) == 0)
    }

    @Test("Under the song, a small subject is brought a little closer, never cut at the sides")
    func zoomsToSubject() {
        let cover = CGRect(x: 0, y: 83, width: 402, height: 402)
        // A small figure right of middle: up to 15% larger, slid toward the middle, still
        // spanning the screen, top unmoved.
        let zoomed = CoverBleedLayout.framed(cover, subject: CGRect(x: 0.45, y: 0.55, width: 0.1, height: 0.12), in: phone)
        #expect(zoomed.width > 402 && zoomed.width <= 402 * 1.15 + 0.001)
        #expect(zoomed.minX <= 0 && zoomed.maxX >= 402 && zoomed.minY == 83)
        // A subject filling the cover: left as it is.
        #expect(CoverBleedLayout.framed(cover, subject: CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9), in: phone) == cover)
        // A small one hard against a side, which zooming would cut: left as it is.
        #expect(CoverBleedLayout.framed(cover, subject: CGRect(x: 0.0, y: 0.4, width: 0.1, height: 0.1), in: phone) == cover)
    }

    @Test("Beside the song, the cover reaches the window's edge and runs past the player's")
    func besideReachesTheEdge() {
        let window = CGSize(width: 1280, height: 820)
        let slot = CGRect(x: 140, y: 170, width: 480, height: 480)
        let rect = CoverBleedLayout.frame(in: window, focus: slot, direction: .beside)
        #expect(rect.minX <= 0.5)
        #expect(rect.maxX > slot.maxX)
        #expect(rect.minY >= 0 && rect.maxY <= window.height)
        #expect(abs(rect.width - rect.height) < 0.001)
        // A figure cut off at the cover's foot stands on the window's bottom edge.
        let standing = CoverBleedLayout.frame(in: window, focus: slot, direction: .beside, standsOnFloor: true)
        #expect(standing.maxY == window.height)
        // A photo running to its edges fills the window's height.
        let tall = CoverBleedLayout.frame(in: window, focus: slot, direction: .beside, fillsHeight: true)
        #expect(tall.minY == 0 && tall.height == window.height && tall.maxX > slot.maxX)
    }

    private func gradientBleed() throws -> CoverBleed {
        // Every edge different: the hardest case for meeting at the corners.
        try #require(CoverBleed(rgba: cover { x, y in
            (UInt8(x * 5), UInt8(y * 5), UInt8(255 - x * 3), 255)
        }, side: 48))
    }

    private func shape(_ size: CGSize, _ rect: CGRect, songEdge: CoverBleed.Edge) -> CoverBleedField.Shape {
        .init(size: size, cover: rect, songEdge: songEdge, featherToSong: 0.2, featherElsewhere: 0.07, settle: 0.32, pointsPerPixel: 4, increasedContrast: false)
    }

    @Test("The colours round the cover have no seam anywhere, corners included")
    func fieldIsContinuous() throws {
        let bleed = try gradientBleed()
        let window = CGSize(width: 1280, height: 820)
        let rect = CGRect(x: 0, y: 80, width: 660, height: 660)
        let field = shape(window, rect, songEdge: .trailing)
        // Walk a loop round the cover, past its corners, a point at a time.
        let margin: CGFloat = 40
        let loop = CGRect(x: rect.minX + 1, y: rect.minY - margin, width: rect.width + margin, height: rect.height + 2 * margin)
        var points: [CGPoint] = []
        for x in stride(from: loop.minX, through: loop.maxX, by: 1) { points.append(CGPoint(x: x, y: loop.minY)) }
        for y in stride(from: loop.minY, through: loop.maxY, by: 1) { points.append(CGPoint(x: loop.maxX, y: y)) }
        for x in stride(from: loop.maxX, through: loop.minX, by: -1) { points.append(CGPoint(x: x, y: loop.maxY)) }
        let colour = CoverBleedField.sampler(bleed: bleed, shape: field)
        var worst = 0.0
        for (a, b) in zip(points, points.dropFirst()) {
            let step = distance(colour(a), colour(b))
            worst = max(worst, step)
        }
        // A point's step on the screen is never a visible jump in colour.
        #expect(worst < 0.02)
        // And crossing the cover's edge, where it fades out, there's no jump either.
        let inside = colour(CGPoint(x: rect.maxX - 0.5, y: rect.midY))
        let outside = colour(CGPoint(x: rect.maxX + 0.5, y: rect.midY))
        #expect(distance(inside, outside) < 0.02)
    }

    @Test("Far from the cover it's one colour, the one the type was chosen for")
    func settlesIntoTheFloor() throws {
        let bleed = try gradientBleed()
        let rect = CGRect(x: 0, y: 90, width: 402, height: 402)
        let field = shape(phone, rect, songEdge: .bottom)
        let colour = CoverBleedField.sampler(bleed: bleed, shape: field)
        let far = colour(CGPoint(x: 30, y: 860))
        let alsoFar = colour(CGPoint(x: 380, y: 860))
        #expect(distance(far, bleed.floor(.bottom)) < 0.01)
        #expect(distance(alsoFar, far) < 0.01)
    }

    @Test("The picture is the container's size, a few points to a pixel")
    func pictureSize() throws {
        let bleed = try gradientBleed()
        let field = CoverBleedField(bleed: bleed, shape: shape(phone, CGRect(x: 0, y: 90, width: 402, height: 402), songEdge: .bottom))
        #expect(field.width == 101)
        #expect(field.height == 219)
        #expect(field.rgba.count == field.width * field.height * 4)
    }
}
