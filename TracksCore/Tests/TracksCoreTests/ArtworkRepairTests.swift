import Testing
import Foundation
@testable import TracksCore

@Suite("Artwork repair")
struct ArtworkRepairTests {

    /// MusicKit hands out `musicKit://artwork/transient/…` for streams, which nothing can
    /// load. Spotting those needs no network.
    @Test("addresses nothing can load are found without a probe")
    func findsUnloadableAddresses() {
        let urls = [
            "https://example.test/cover.jpg",
            "musicKit://artwork/transient/abc",
            "http://example.test/old.jpg",
            "",
        ]
        #expect(ArtworkRepair.unloadable(among: urls) == ["musicKit://artwork/transient/abc", ""])
    }

    @Test("a probe that answers yes for everything finds nothing broken")
    func nothingBroken() async {
        let broken = await ArtworkRepair.broken(
            among: (0..<20).map { "https://example.test/\($0).jpg" },
            probe: { _ in true }
        )
        #expect(broken.isEmpty)
    }

    @Test("only the covers the probe rejects are returned")
    func findsBroken() async {
        let urls = (0..<20).map { "https://example.test/\($0).jpg" }
        let gone: Set<String> = ["https://example.test/3.jpg", "https://example.test/17.jpg"]
        let broken = await ArtworkRepair.broken(among: urls, probe: { !gone.contains($0) })

        #expect(broken == gone)
    }

    /// More URLs than the concurrency limit, to check the task group refills rather than
    /// stopping after the first batch.
    @Test("every cover is probed, not just the first batch")
    func probesEverything() async {
        let urls = (0..<50).map { "https://example.test/\($0).jpg" }
        let seen = Probed()
        _ = await ArtworkRepair.broken(among: urls, probe: { await seen.add($0); return true })

        #expect(await seen.count == 50)
    }

    @Test("no covers means no probing")
    func emptyInput() async {
        let broken = await ArtworkRepair.broken(among: [], probe: { _ in false })
        #expect(broken.isEmpty)
    }

    /// Forgetting a cover we simply couldn't reach would blank the row until the catalog is
    /// asked again, which is worse than keeping the one we have.
    @Test("a status that means the request failed is not a missing cover", arguments: [500, 503, 429])
    func serverErrorsAreNotGone(status: Int) {
        #expect(!ArtworkRepair.gone.contains(status))
    }

    @Test("the statuses that mean the cover was taken down", arguments: [403, 404, 410])
    func takenDownStatuses(status: Int) {
        #expect(ArtworkRepair.gone.contains(status))
    }

    @Test("a repair that changed nothing reads as nothing wrong")
    func reportReadsAsClean() {
        #expect(ArtworkRepairReport(checked: 40, cleared: 0, restored: 0).foundNothingWrong)
        #expect(!ArtworkRepairReport(checked: 40, cleared: 3, restored: 2).foundNothingWrong)
    }
}

/// Collects what the probe was asked about, across the task group's threads.
private actor Probed {
    private var urls: Set<String> = []
    var count: Int { urls.count }
    func add(_ url: String) { urls.insert(url) }
}
