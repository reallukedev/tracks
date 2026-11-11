import Testing
@testable import TracksCore

@Suite("Chart ceiling")
struct ChartCeilingTests {
    @Test("rounds up to a tenth of the value's order of magnitude", arguments: [
        (143_700.0, 150_000.0),
        (3_241.0, 3_300.0),
        (10_100.0, 11_000.0),
        (7.31, 7.4),
        (0.42, 0.42),
    ])
    func roundsUp(value: Double, expected: Double) {
        #expect(abs(ChartCeiling.rounded(value) - expected) < 1e-9)
    }

    @Test("a value already on a step stays there")
    func onAStep() {
        #expect(ChartCeiling.rounded(1_500) == 1_500)
        #expect(ChartCeiling.rounded(100) == 100)
    }

    @Test("a growing running total moves the top rarely, not with every song")
    func growingTotal() {
        // About four minutes a song, over a few hundred songs.
        let tops = Set(stride(from: 143_000.0, to: 144_200, by: 4).map(ChartCeiling.rounded))
        #expect(tops == [150_000])
    }

    @Test("never lower than the value, and at most a tenth over it", arguments: [1.0, 9.99, 12.5, 999, 1_001, 54_321, 987_654])
    func headroom(value: Double) {
        let top = ChartCeiling.rounded(value)
        #expect(top >= value)
        #expect(top <= value * 1.1 + 1e-9)
    }

    @Test("nothing, a negative or a non-finite value is left alone", arguments: [0.0, -5, .infinity, .nan])
    func leftAlone(value: Double) {
        let top = ChartCeiling.rounded(value)
        #expect(top == value || (top.isNaN && value.isNaN))
    }
}
