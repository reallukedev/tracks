import Foundation

/// What a repair pass did, for the message Settings shows afterwards.
public struct ArtworkRepairReport: Sendable, Equatable {
    /// Distinct cover addresses that were looked at.
    public var checked: Int = 0
    /// Songs whose cover was forgotten because nothing could load it. Higher than the number
    /// of addresses, since an album's songs share one.
    public var cleared: Int = 0
    /// Songs that got a cover back from the catalog.
    public var restored: Int = 0

    public init(checked: Int = 0, cleared: Int = 0, restored: Int = 0) {
        self.checked = checked
        self.cleared = cleared
        self.restored = restored
    }

    public var foundNothingWrong: Bool { cleared == 0 }
}

/// Finds stored covers that no longer load, so they can be fetched again.
///
/// Two things go wrong. A `musicKit://artwork/transient/…` URL was never loadable by anything
/// (see ``ArtworkURL``) and can be spotted without a network. An `https` URL can still rot:
/// Apple moves artwork when a release changes, and the old address 404s. Only a request tells
/// you that, so the caller supplies one.
public enum ArtworkRepair {
    /// How many covers to probe at once. Enough to get through a few thousand quickly,
    /// gentle enough not to look like an attack on Apple's CDN.
    public static let probeConcurrency = 6

    /// Splits stored covers into the ones whose address can't be loaded at all.
    public static func unloadable(among urls: some Sequence<String>) -> Set<String> {
        Set(urls.filter { !ArtworkURL.isLoadable($0) })
    }

    /// Probes each URL and returns the ones that didn't come back.
    ///
    /// - Parameter probe: answers whether the image is still there. A probe that can't tell
    ///   (no network, a timeout) must answer `true`, so a repair run offline doesn't wipe
    ///   every cover in the history.
    public static func broken(
        among urls: [String],
        probe: @escaping @Sendable (String) async -> Bool
    ) async -> Set<String> {
        guard !urls.isEmpty else { return [] }
        var broken: Set<String> = []
        var next = 0

        await withTaskGroup(of: (String, Bool).self) { group in
            func addTask() {
                guard next < urls.count else { return }
                let url = urls[next]
                next += 1
                group.addTask { (url, await probe(url)) }
            }

            for _ in 0..<min(probeConcurrency, urls.count) { addTask() }
            while let (url, isThere) = await group.next() {
                if !isThere { broken.insert(url) }
                addTask()
            }
        }
        return broken
    }

    /// The probe used in the app: a HEAD request to the cover's address.
    ///
    /// Only a definite "not there" counts. A timeout, a server error or no network all answer
    /// `true`, because forgetting a cover we can't reach would leave the row blank until the
    /// catalog is asked again, worse than the cover we already have.
    public static func networkProbe(
        session: URLSession = .shared,
        timeout: TimeInterval = 10
    ) -> @Sendable (String) async -> Bool {
        { urlString in
            guard let url = URL(string: urlString) else { return false }
            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.httpMethod = "HEAD"
            guard let response = try? await session.data(for: request).1,
                  let status = (response as? HTTPURLResponse)?.statusCode
            else { return true }
            return !gone.contains(status)
        }
    }

    /// Statuses that mean the cover has been taken down rather than that the request failed.
    static let gone: Set<Int> = [403, 404, 410]
}
