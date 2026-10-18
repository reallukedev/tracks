import Foundation
import CryptoKit

/// Last.fm's `api_sig` request signature.
///
/// MD5 of each parameter's `name + value`, sorted by name and joined with no separators,
/// with the shared secret appended. `format` and `callback` are sent but must not be signed.
/// Any mistake just gets "Invalid method signature supplied", hence the tests.
public enum LastFMSignature {
    static let unsigned: Set<String> = ["format", "callback", "api_sig"]

    public static func sign(_ parameters: [String: String], secret: String) -> String {
        let signable = parameters
            .filter { !unsigned.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { $0.key + $0.value }
            .joined()
        return md5(signable + secret)
    }

    /// Last.fm specifies MD5.
    static func md5(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
