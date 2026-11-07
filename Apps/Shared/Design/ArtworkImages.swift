import Foundation
import ImageIO
import CryptoKit
import TracksCore

/// Album covers, fetched once, decoded off the main actor at the size they're drawn, and
/// kept in memory.
///
/// `AsyncImage` keeps nothing in memory. In a long list every cover that scrolled back into
/// view was fetched again from the URL cache and a 300-pixel JPEG decoded again, and the
/// generated cover showed underneath in the meantime. Here a cover already seen is ready in
/// the same frame, and a new one arrives decoded, so scrolling only has to draw it.
nonisolated final class ArtworkImages: Sendable {
    static let shared = ArtworkImages()

    struct Key: Hashable, Sendable {
        let url: URL
        /// The longest side in pixels. A cover is decoded for the size it's drawn at.
        let pixels: Int
    }

    /// Thread-safe, and emptied by the system under memory pressure.
    private nonisolated(unsafe) let images: NSCache<KeyBox, ImageBox> = {
        let cache = NSCache<KeyBox, ImageBox>()
        // Enough for several screens of rows at any size, measured in decoded pixels.
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()
    private let loads = InFlight<Key, CGImage?>()

    /// A cover already decoded at this size, without waiting.
    func cached(_ key: Key) -> CGImage? {
        images.object(forKey: KeyBox(key))?.image
    }

    /// The cover at this size. Rows asking for the same cover at once share one fetch.
    func image(for key: Key) async -> CGImage? {
        if let cached = cached(key) { return cached }
        let image = await loads.load(key) { await Self.fetch(key) }
        if let image {
            images.setObject(ImageBox(image), forKey: KeyBox(key), cost: image.bytesPerRow * image.height)
        }
        return image
    }

    /// Fetches covers before they're shown, so the first rows' covers are on disk by the time
    /// they ask: from a server like Octo, which takes seconds to find each, they'd otherwise
    /// arrive one by one as the rows come in. In order, two at a time.
    @concurrent
    func warm(_ urls: [URL]) async {
        var seen = Set<URL>()
        var pending = urls.filter { seen.insert($0).inserted }.makeIterator()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                guard let url = pending.next() else { break }
                group.addTask { _ = await Self.data(for: url) }
            }
            while await group.next() != nil {
                guard let url = pending.next() else { continue }
                group.addTask { _ = await Self.data(for: url) }
            }
        }
    }

    /// Whether a cover is there to be had, fetching it if it isn't on disk yet: false for a
    /// server's stand-in, or one it couldn't send.
    @concurrent
    func hasCover(_ url: URL) async -> Bool {
        await Self.data(for: url) != nil
    }

    /// For covers whose addresses shouldn't be kept: nothing goes in the URL cache.
    private static let privateSession = URLSession(configuration: .ephemeral)

    @concurrent
    private static func fetch(_ key: Key) async -> CGImage? {
        guard let data = await data(for: key.url), let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: key.pixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // Decode now, here, rather than when the image is first drawn on the main thread.
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// A cover's file. The shared session's URL cache keeps it, so it isn't downloaded again
    /// after it falls out of memory. A music server's cover can't go there, as its address
    /// carries a sign-in token that mustn't be written to disk, so it's kept in a folder of its
    /// own under a name made from the address without it: a server like Octo takes seconds to
    /// find each cover, and without this found every one again on every launch.
    private static func data(for url: URL) async -> Data? {
        guard url.path(percentEncoded: false).hasSuffix("/rest/getCoverArt") else {
            return await download(url, with: .shared)
        }
        let name = savedName(for: url)
        let saved = serverCovers.appending(path: name)
        if await misses.isRecent(name) { return nil }
        if let data = try? Data(contentsOf: saved) {
            // Kept before stand-ins were told apart: let it go, and look again.
            guard await standIns.isStandIn(data, from: url) else { return data }
            try? FileManager.default.removeItem(at: saved)
        }
        // Fetched ahead and asked for by a row at once: one download.
        return await downloads.load(url) {
            // One at a time: a server like Octo finds each cover on iTunes, Deezer or Last.fm,
            // and asked for many at once, they turn it away and it finds none.
            guard let data = (try? await serverDownloads.run { await download(url, with: privateSession) }) ?? nil else { return nil }
            if await standIns.isStandIn(data, from: url) {
                await misses.note(name)
                return nil
            }
            try? FileManager.default.createDirectory(at: serverCovers, withIntermediateDirectories: true)
            try? data.write(to: saved, options: .atomic)
            return data
        }
    }

    private static let downloads = InFlight<URL, Data?>()
    private static let serverDownloads = AsyncLimiter(limit: 1)
    private static let standIns = StandIns()
    private static let misses = Misses()

    /// Whether a cover that didn't come is worth asking for again later: a server's, which
    /// may have been turned away by the services it finds covers on.
    static func mayArriveLater(_ url: URL) -> Bool {
        url.path(percentEncoded: false).hasSuffix("/rest/getCoverArt")
    }

    /// What a server sends in place of a cover it hasn't got. Octo sends its own picture, with
    /// a 200, for a cover it couldn't find, often only because the services it asked were busy;
    /// kept as the cover, it would stay forever. Found by asking each server once for covers
    /// that can't exist, and remembering what comes back.
    private actor StandIns {
        private var known: [String: Set<String>] = [:]
        private var asking: [String: Task<Set<String>, Never>] = [:]

        func isStandIn(_ data: Data, from url: URL) async -> Bool {
            await pictures(from: url).contains(ArtworkImages.digest(data))
        }

        private func pictures(from url: URL) async -> Set<String> {
            let server = "\(url.scheme ?? "")://\(url.host() ?? ""):\(url.port ?? 0)"
            if let pictures = known[server] { return pictures }
            if let task = asking[server] { return await task.value }
            let task = Task { await Self.ask(like: url) }
            asking[server] = task
            let pictures = await task.value
            asking[server] = nil
            known[server] = pictures
            return pictures
        }

        /// Octo's picture for a cover it can't place, and for one its library hasn't got,
        /// which it may send unbranded; a plain server's own "no cover" picture, if it has one.
        private static func ask(like url: URL) async -> Set<String> {
            var pictures = Set<String>()
            for id in ["ext-album-tracks-no-such-cover", "tracks-no-such-cover"] {
                guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { continue }
                components.queryItems = (components.queryItems ?? []).map { $0.name == "id" ? URLQueryItem(name: "id", value: id) : $0 }
                guard let probe = components.url, let data = await download(probe, with: privateSession) else { continue }
                pictures.insert(ArtworkImages.digest(data))
            }
            return pictures
        }
    }

    /// Covers a server hadn't got, and when: asked again once Octo would look again, five
    /// minutes on, rather than every time a row appears.
    private actor Misses {
        private var at: [String: Date] = [:]

        func isRecent(_ name: String) -> Bool {
            guard let when = at[name] else { return false }
            return Date.now.timeIntervalSince(when) < ArtworkImages.retryAfter
        }

        func note(_ name: String) { at[name] = .now }
    }

    /// How long a cover a server hadn't got is left before it's asked for again.
    static let retryAfter: TimeInterval = 5 * 60 + 10

    fileprivate static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func download(_ url: URL, with session: URLSession) async -> Data? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
        else { return nil }
        return data
    }

    /// Where server covers are kept. Caches, so the system can clear it when space is short.
    private static let serverCovers = URL.cachesDirectory.appending(path: "ServerCovers", directoryHint: .isDirectory)

    /// A server cover's file name: the address without the sign-in (username, token, salt,
    /// password), hashed, so nothing that signs in is written down.
    static func savedName(for url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let kept = components?.queryItems?
            .filter { !["u", "t", "s", "p"].contains($0.name) }
            .sorted { $0.name < $1.name }
        components?.queryItems = kept
        let stable = components?.url?.absoluteString ?? url.path()
        return SHA256.hash(data: Data(stable.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Loads in progress, so a cover on screen in ten rows is fetched once.
    private actor InFlight<Key: Hashable & Sendable, Value: Sendable> {
        private var tasks: [Key: Task<Value, Never>] = [:]

        func load(_ key: Key, _ work: @escaping @Sendable () async -> Value) async -> Value {
            if let task = tasks[key] { return await task.value }
            let task = Task { await work() }
            tasks[key] = task
            let image = await task.value
            tasks[key] = nil
            return image
        }
    }

    private final class KeyBox: NSObject {
        let key: Key
        init(_ key: Key) { self.key = key }
        override var hash: Int { key.hashValue }
        override func isEqual(_ object: Any?) -> Bool { (object as? KeyBox)?.key == key }
    }

    private final class ImageBox {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }
}
