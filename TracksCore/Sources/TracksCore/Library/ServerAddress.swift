import Foundation

/// A server's address as someone types it, made into one Tracks can reach: a music server, or
/// Lidarr.
///
/// Home servers rarely have https, and people type what their browser shows without the
/// scheme: "192.168.1.223:5274". So an address without one gains http when it can only be on
/// the home network (an IP address, `localhost`, a `.local` name, a one-word name like "nas")
/// or names a port, since a server on its own port is almost always a home one. Anything else
/// gains https: "music.example.com" is on the internet, where it should be encrypted. Spaces
/// around it and slashes after it go. An address that says its scheme keeps it.
public enum ServerAddress {
    /// The address to connect to, or nil for one that can't be a web server's.
    public static func url(from text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Asked before the slashes go, so "http://" alone isn't read as a host named "http".
        let hasScheme = trimmed.contains("://")
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return nil }

        if hasScheme {
            guard var components = URLComponents(string: trimmed),
                  let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https"
            else { return nil }
            components.scheme = scheme
            return reachable(components)
        }

        // A bare IPv6 address has colons of its own: it goes in brackets before a port can follow.
        if trimmed.filter({ $0 == ":" }).count > 1, !trimmed.hasPrefix("[") {
            trimmed = "[\(trimmed)]"
        }
        guard var components = URLComponents(string: "http://" + trimmed), let host = components.host else { return nil }
        components.scheme = isAtHome(host: host, port: components.port) ? "http" : "https"
        return reachable(components)
    }

    /// Whether an address without a scheme is most likely a home server's, reached over http.
    static func isAtHome(host: String, port: Int?) -> Bool {
        if let port { return port != 443 }
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if name == "localhost" || name.hasSuffix(".local") || name.hasSuffix(".home.arpa") { return true }
        // An IP address, either kind.
        if name.contains(":") || name.split(separator: ".").allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
            return true
        }
        // A name with no dots only resolves on the network it's on.
        return !name.contains(".")
    }

    private static func reachable(_ components: URLComponents) -> URL? {
        guard let host = components.host, !host.isEmpty, let url = components.url else { return nil }
        return url
    }
}
