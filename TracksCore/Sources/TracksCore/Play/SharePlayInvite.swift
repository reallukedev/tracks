import Foundation
import CryptoKit

/// The code a host shows, in the car or on its iPhone, for the people with it to scan and
/// join its SharePlay: a `tracks://` link carrying a key made for this one session.
///
///     tracks://shareplay/Hk3v0Q2mWc8yJ1pXbA7t9g
///
/// The key is all a guest needs, and all a stranger lacks. The host offers itself nearby
/// under a tag worked out from the key, so a guest finds the right iPhone among several, and
/// the connection is encrypted with the key itself, so an iPhone that hasn't scanned the code
/// can't join or listen in. Ending SharePlay makes a new key, and an old photo of the code
/// stops working.
public struct SharePlayInvite: Sendable, Hashable {
    /// Sixteen random bytes.
    public let key: Data

    public static let keyLength = 16

    /// A new invite, with a key no one has seen.
    public init() {
        key = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
    }

    /// An invite for a key, or nil for one that isn't the right length.
    public init?(key: Data) {
        guard key.count == Self.keyLength else { return nil }
        self.key = key
    }

    // MARK: - The link

    /// Where the link goes, after `tracks://`.
    public static let host = "shareplay"

    /// The link the code holds. Forty characters, which fit a QR code of 29 by 29 squares,
    /// the fewest and so the largest, for a camera reading it from across a car.
    public var url: URL {
        URL(string: "tracks://\(Self.host)/\(Self.base64URL(key))")!
    }

    /// The link the code holds once Tracks’ App Clip is on the App Store: Apple's own link
    /// for it, which opens Tracks where it's installed and the App Clip where it isn't, so
    /// anyone can join. Longer, so its code has a few more, smaller squares.
    ///
    ///     https://appclip.apple.com/id?p=com.luke.tracks.Clip&c=Hk3v0Q2mWc8yJ1pXbA7t9g
    public func appClipURL(bundleID: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.appClipHost
        components.path = "/id"
        components.queryItems = [URLQueryItem(name: "p", value: bundleID), URLQueryItem(name: "c", value: Self.base64URL(key))]
        return components.url!
    }

    static let appClipHost = "appclip.apple.com"

    /// The invite a link carries, Tracks’ own or the App Clip's, or nil for any other link.
    public init?(url: URL) {
        if url.scheme?.lowercased() == "https", url.host()?.lowercased() == Self.appClipHost {
            guard let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "c" })?.value,
                  let key = Self.data(base64URL: code)
            else { return nil }
            self.init(key: key)
            return
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard url.scheme?.lowercased() == "tracks",
              url.host()?.lowercased() == Self.host,
              parts.count == 1,
              let key = Self.data(base64URL: parts[0])
        else { return nil }
        self.init(key: key)
    }

    // MARK: - Finding and securing

    /// What the host is known by nearby: the first bytes of the key's hash, which say which
    /// host has this key without giving the key away.
    public var tag: String {
        SHA256.hash(data: key).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// The secret both ends encrypt with.
    public var secret: Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(Self.pskIdentity.utf8), using: SymmetricKey(data: key)))
    }

    /// The name both ends give the secret.
    public static let pskIdentity = "Tracks SharePlay"

    // MARK: - Base64 for links

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func data(base64URL string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}
