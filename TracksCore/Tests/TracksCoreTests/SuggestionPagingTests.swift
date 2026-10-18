import Testing
import Synchronization
@testable import TracksCore

@Suite("Paging suggestions")
struct SuggestionPagingTests {
    /// A source of suggestions that finds a page of songs a step, some of which are left out.
    @MainActor
    final class FakeSource {
        var pages: [[Int]]
        var shown: [Int] = []
        var steps = 0
        let keeps: (Int) -> Bool

        init(pages: [[Int]], keeps: @escaping (Int) -> Bool = { _ in true }) {
            self.pages = pages
            self.keeps = keeps
        }

        func step() -> Bool {
            steps += 1
            guard !pages.isEmpty else { return false }
            shown += SuggestionPaging.new(pages.removeFirst().filter(keeps), known: shown, by: \.self)
            return true
        }
    }

    @Test("a shelf in columns wants enough to finish its last column, or a whole new one", arguments: [
        (0, 4), (1, 3), (3, 1), (4, 4), (5, 3), (8, 4),
    ])
    func wanted(showing: Int, wants: Int) {
        #expect(SuggestionPaging.wanted(showing: showing, perColumn: 4) == wants)
    }

    @Test("a page whose songs are mostly left out asks again until it's full")
    @MainActor
    func fillsPastLeftOut() async {
        // Only even songs are kept: each page of four brings two.
        let source = FakeSource(pages: [[1, 2, 3, 4], [5, 6, 7, 8], [9, 10, 11, 12], [13, 14]], keeps: { $0.isMultiple(of: 2) })
        let came = await SuggestionPaging.fill(want: 4, maxSteps: 6, count: { source.shown.count }, step: { source.step() })
        #expect(came == 4)
        #expect(source.shown == [2, 4, 6, 8])
        #expect(source.steps == 2)
    }

    @Test("stops when there's nowhere left to look")
    @MainActor
    func stopsWhenExhausted() async {
        let source = FakeSource(pages: [[1]])
        let came = await SuggestionPaging.fill(want: 8, maxSteps: 6, count: { source.shown.count }, step: { source.step() })
        #expect(came == 1)
        #expect(source.steps == 2)
    }

    @Test("a source that never brings anything is asked only so many times")
    @MainActor
    func boundedWhenNothingComes() async {
        let source = FakeSource(pages: Array(repeating: [1, 3, 5], count: 20), keeps: { $0.isMultiple(of: 2) })
        let came = await SuggestionPaging.fill(want: 4, maxSteps: 3, count: { source.shown.count }, step: { source.step() })
        #expect(came == 0)
        #expect(source.steps == 3)
    }

    @Test("songs found again aren't shown twice")
    @MainActor
    func noDuplicates() async {
        let source = FakeSource(pages: [[1, 2], [2, 3], [1, 3, 4], [5]])
        await SuggestionPaging.fill(want: 5, maxSteps: 10, count: { source.shown.count }, step: { source.step() })
        #expect(source.shown == [1, 2, 3, 4, 5])
    }

    @Test("new keeps the first of each, leaving out what's known")
    func newDedupes() {
        let new = SuggestionPaging.new(["a", "b", "A", "c", "b"], known: ["c"], by: { $0.lowercased() })
        #expect(new == ["a", "b"])
    }

    @Test("kept keeps order, whatever order the answers come in")
    func keptKeepsOrder() async {
        let kept = await SuggestionPaging.kept(Array(1...12), limit: 6) { number in
            // Later numbers answer first.
            try? await Task.sleep(for: .milliseconds(13 - number))
            return number % 3 != 0
        }
        #expect(kept == [1, 2, 4, 5, 7, 8, 10, 11])
    }

    @Test("kept asks about no more than the limit at once")
    func keptHonoursLimit() async {
        let running = Mutex((now: 0, most: 0))
        _ = await SuggestionPaging.kept(Array(0..<20), limit: 6) { _ in
            running.withLock { $0.now += 1; $0.most = max($0.most, $0.now) }
            try? await Task.sleep(for: .milliseconds(5))
            running.withLock { $0.now -= 1 }
            return true
        }
        let most = running.withLock { $0.most }
        #expect(most <= 6)
        #expect(most > 1)
    }

    @Test("kept of nothing is nothing")
    func keptEmpty() async {
        let kept = await SuggestionPaging.kept([Int]()) { _ in true }
        #expect(kept.isEmpty)
    }
}
