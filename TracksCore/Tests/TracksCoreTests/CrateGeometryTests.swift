import Testing
@testable import TracksCore

@Suite("Play's crate")
struct CrateGeometryTests {
    /// The iPhone's crate: a 232-point cover, 8 points between places.
    let pitch = 240.0

    // MARK: - The fan

    @Test("Records either side sit further out and smaller, one after another")
    func fanStepsOut() {
        #expect(CrateFan.reach(0) == 0)
        #expect(CrateFan.scale(0) == 1)
        for a in 1...6 {
            let (nearer, farther) = (Double(a - 1), Double(a))
            #expect(CrateFan.reach(farther) > CrateFan.reach(nearer))
            #expect(CrateFan.scale(farther) < CrateFan.scale(nearer))
        }
    }

    @Test("The first record beside the front is tucked just behind it, not clear of it")
    func firstRecordTucksBehind() {
        // Its inner edge, reach less half its width, falls inside the front cover's half.
        let innerEdge = CrateFan.reach(1) - CrateFan.scale(1) / 2
        #expect(innerEdge < 0.5)
        #expect(innerEdge > 0.3)
    }

    @Test("Halfway to the front, the record coming and the one going stand clear of each other")
    func crossingRecordsDontOverlap() {
        // They swap which is on top here: each one's inner edge must be past the middle, with
        // room for the few points its turn adds to its near edge.
        let innerEdge = CrateFan.reach(0.5) - CrateFan.scale(0.5) / 2
        #expect(innerEdge > 0.02)
    }

    @Test("Moving toward the front, a record never goes back the way it came",
          arguments: stride(from: 0.0, through: 3.0, by: 0.05).map(\.self))
    func reachKeepsGrowing(a: Double) {
        #expect(CrateFan.reach(a + 0.05) > CrateFan.reach(a))
    }

    @Test("Records far out never shrink to nothing")
    func scaleHasAFloor() {
        #expect(CrateFan.scale(40) == 0.5)
    }

    @Test("A phone fits one record a side; a wide Mac window fits several", arguments: [
        (width: 402.0, side: 232.0, depth: 1.0),
        (width: 1528.0, side: 306.0, depth: 4.0),
    ])
    func depthFitsTheWidth(width: Double, side: Double, depth: Double) {
        #expect(CrateFan.depth(width: width, side: side) == depth)
    }

    @Test("Every record counted in the depth fits inside the fade at the edges")
    func depthFits() {
        for width in stride(from: 300.0, through: 3000, by: 50) {
            let side = 260.0
            let depth = CrateFan.depth(width: width, side: side)
            #expect(depth >= 1)
            #expect(depth <= Double(CrateFan.deepest))
            guard depth > 1 else { continue }
            let outerEdge = (CrateFan.reach(depth) + CrateFan.scale(depth) / 2) * side
            #expect(outerEdge <= width / 2 * 0.91)
        }
    }

    @Test("Before the width is known, one record a side")
    func depthWithoutWidth() {
        #expect(CrateFan.depth(width: 0, side: 232) == 1)
        #expect(CrateFan.depth(width: 400, side: 0) == 1)
    }

    // MARK: - Position

    @Test("The place in the middle is the nearest record's")
    func placeRounds() {
        #expect(CratePosition(offset: 0, pitch: pitch, places: 10).place == 0)
        #expect(CratePosition(offset: pitch * 0.49, pitch: pitch, places: 10).place == 0)
        #expect(CratePosition(offset: pitch * 0.51, pitch: pitch, places: 10).place == 1)
        #expect(CratePosition(offset: pitch * 7, pitch: pitch, places: 10).place == 7)
    }

    @Test("Resting part way to the next record is between records, though the place rounds back")
    func restingPartWayIsBetween() {
        // A Mac window's crate left 0.4 of a record past Tracks Radio, under the sidebar's inset.
        let pitch = 326.0
        let partWay = CratePosition(offset: pitch * 3.4 - 200, inset: 200, pitch: pitch, places: 10)
        #expect(partWay.place == 3)
        #expect(partWay.isBetween)
        #expect(!CratePosition(offset: pitch * 3 - 200, inset: 200, pitch: pitch, places: 10).isBetween)
        #expect(!CratePosition(offset: pitch * 3 + 0.25, pitch: pitch, places: 10).isBetween)
    }

    @Test("Pulled past an end isn't between records: it springs back to the end by itself")
    func pastEndIsNotBetween() {
        #expect(!CratePosition(offset: -pitch * 0.4, pitch: pitch, places: 10).isBetween)
        #expect(!CratePosition(offset: pitch * 9.4, pitch: pitch, places: 10).isBetween)
    }

    @Test("Under the Mac's sidebar the place counts the inset, not the record before the middle")
    func placeCountsTheInset() {
        // As a maximized Mac window reports it at rest on the 18th record: the sidebar's
        // 200 points of inset aren't in the offset.
        let pitch = 326.0
        #expect(CratePosition(offset: 5342, inset: 200, pitch: pitch, places: 40).place == 17)
        #expect(CratePosition(offset: -200, inset: 200, pitch: pitch, places: 40).place == 0)
        #expect(!CratePosition(offset: -200, inset: 200, pitch: pitch, places: 40).isPastEnd)
    }

    @Test("A flick under the Mac's sidebar rests where the crate itself centres a record")
    func restCountsTheInset() {
        // Centred on the 18th record by the crate, a maximized Mac window reports 5342 with
        // the sidebar's 200 points of inset. A flick ending near there has to rest there too.
        let pitch = 326.0
        let last = pitch * 39
        #expect(CrateRest.offset(for: 5300, inset: 200, from: nil, pitch: pitch, last: last) == 5342)
        #expect(CrateRest.offset(for: -150, inset: 200, from: nil, pitch: pitch, last: last) == -200)
        #expect(CrateRest.offset(for: 99_999, inset: 200, from: nil, pitch: pitch, last: last) == last - 200)
    }

    @Test("Pulled past an end, the place holds at the end rather than running off the row")
    func placeHoldsAtTheEnds() {
        #expect(CratePosition(offset: -pitch * 2, pitch: pitch, places: 10).place == 0)
        #expect(CratePosition(offset: pitch * 14, pitch: pitch, places: 10).place == 9)
    }

    @Test("Past an end only once pulled a hair beyond it, not while settling onto it")
    func pastEnd() {
        let places = 5
        let last = Double(places - 1) * pitch
        #expect(!CratePosition(offset: 0, pitch: pitch, places: places).isPastEnd)
        #expect(!CratePosition(offset: -pitch * 0.05, pitch: pitch, places: places).isPastEnd)
        #expect(CratePosition(offset: -pitch * 0.2, pitch: pitch, places: places).isPastEnd)
        #expect(!CratePosition(offset: last, pitch: pitch, places: places).isPastEnd)
        #expect(!CratePosition(offset: last + pitch * 0.05, pitch: pitch, places: places).isPastEnd)
        #expect(CratePosition(offset: last + pitch * 0.2, pitch: pitch, places: places).isPastEnd)
        #expect(!CratePosition(offset: pitch * 2, pitch: pitch, places: places).isPastEnd)
    }

    @Test("Scrolling one record changes the place once: one detent a record")
    func oneDetentARecord() {
        var changes = 0
        var previous = CratePosition(offset: 0, pitch: pitch, places: 10)
        for step in 0...240 {
            let position = CratePosition(offset: Double(step), pitch: pitch, places: 10)
            if position.place != previous.place { changes += 1 }
            previous = position
        }
        #expect(changes == 1)
        #expect(previous.place == 1)
    }

    @Test("An empty crate, or one not laid out yet, is at its start")
    func emptyPosition() {
        let empty = CratePosition(offset: 500, pitch: pitch, places: 0)
        #expect(empty.place == 0)
        #expect(!empty.isPastEnd)
        let unlaid = CratePosition(offset: 500, pitch: 0, places: 8)
        #expect(unlaid.place == 0)
        #expect(!unlaid.isPastEnd)
    }

    // MARK: - Coming to rest

    @Test("A scroll comes to rest with the nearest record in the middle")
    func restsOnARecord() {
        let last = pitch * 9
        #expect(CrateRest.offset(for: pitch * 2.3, from: nil, pitch: pitch, last: last) == pitch * 2)
        #expect(CrateRest.offset(for: pitch * 2.6, from: nil, pitch: pitch, last: last) == pitch * 3)
    }

    @Test("A flick carries the crate a few records at most, either way")
    func flickIsHeldToAFew() {
        let last = pitch * 30
        let reach = CrateRest.flingReach
        #expect(CrateRest.offset(for: pitch * 25, from: 10, pitch: pitch, last: last) == pitch * Double(10 + reach))
        #expect(CrateRest.offset(for: 0, from: 10, pitch: pitch, last: last) == pitch * Double(10 - reach))
        #expect(CrateRest.offset(for: pitch * 12, from: 10, pitch: pitch, last: last) == pitch * 12)
    }

    @Test("It never rests beyond the first or last record")
    func restsInsideTheRow() {
        let last = pitch * 4
        #expect(CrateRest.offset(for: -pitch * 3, from: 1, pitch: pitch, last: last) == 0)
        #expect(CrateRest.offset(for: pitch * 9, from: 3, pitch: pitch, last: last) == last)
        #expect(CrateRest.offset(for: pitch * 9, from: nil, pitch: pitch, last: last) == last)
    }

    // MARK: - The row

    @Test("Without quiet records at the ends, each place is the record at that index")
    func rowWithoutEnds() {
        let row = CrateRow(records: 3, hasLeadingEnd: false, hasTrailingEnd: false)
        #expect(row.places == 3)
        #expect((0..<3).map(row.slot(at:)) == [.record(0), .record(1), .record(2)])
        #expect(row.slot(at: -1) == nil)
        #expect(row.slot(at: 3) == nil)
        #expect(row.place(of: .leadingEnd) == nil)
        #expect(row.place(of: .trailingEnd) == nil)
    }

    @Test("The quiet records hold the first and last places while more songs are looked for")
    func rowWithEnds() {
        let row = CrateRow(records: 3, hasLeadingEnd: true, hasTrailingEnd: true)
        #expect(row.places == 5)
        #expect((0..<5).map(row.slot(at:)) == [.leadingEnd, .record(0), .record(1), .record(2), .trailingEnd])
        #expect(row.slot(at: 5) == nil)
    }

    @Test("Finding a place and reading it back gives the same thing, either way round", arguments: [
        (leading: false, trailing: false),
        (leading: true, trailing: false),
        (leading: false, trailing: true),
        (leading: true, trailing: true),
    ])
    func rowRoundTrips(leading: Bool, trailing: Bool) throws {
        let row = CrateRow(records: 6, hasLeadingEnd: leading, hasTrailingEnd: trailing)
        for place in 0..<row.places {
            let slot = try #require(row.slot(at: place))
            #expect(row.place(of: slot) == place)
        }
    }

    @Test("A record that isn't in the row has no place")
    func rowMissingRecord() {
        let row = CrateRow(records: 2, hasLeadingEnd: true, hasTrailingEnd: false)
        #expect(row.place(of: .record(2)) == nil)
        #expect(row.place(of: .record(-1)) == nil)
    }

    @Test("An empty row has only its quiet records")
    func emptyRow() {
        let row = CrateRow(records: 0, hasLeadingEnd: true, hasTrailingEnd: true)
        #expect(row.places == 2)
        #expect(row.slot(at: 0) == .leadingEnd)
        #expect(row.slot(at: 1) == .trailingEnd)
        #expect(CrateRow(records: -3, hasLeadingEnd: false, hasTrailingEnd: false).places == 0)
    }

    @Test("A crate of one record always rests on it")
    func singleRecord() {
        #expect(CrateRest.offset(for: pitch * 0.8, from: 0, pitch: pitch, last: 0) == 0)
        #expect(CrateRest.offset(for: -pitch, from: 0, pitch: pitch, last: -12) == 0)
    }
}
