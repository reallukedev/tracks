import Foundation

/// A `tracks://` link: where a tap on a widget opens the app.
///
/// Plain Foundation, with no app types, because the widget extension compiles this file too:
/// the widgets build the links and the apps follow them (see `DeepLink+Routing.swift`).
///
///     tracks://summary
///     tracks://history
///     tracks://song?title=Tidewater&artist=June%20Atlas
enum DeepLink: Hashable, Sendable {
    /// The Listening widget's week.
    case summary
    /// The Today widget's list.
    case history
    /// One song's page. By title and artist rather than a row id, since that's how the apps
    /// group a song's plays, and a row the widget saw may since have been merged away.
    case song(title: String, artistName: String)

    /// Registered under `CFBundleURLTypes` in both apps' Info.plist.
    static let scheme = "tracks"

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .summary:
            components.host = "summary"
        case .history:
            components.host = "history"
        case .song(let title, let artistName):
            components.host = "song"
            components.queryItems = [
                URLQueryItem(name: "title", value: title),
                URLQueryItem(name: "artist", value: artistName),
            ]
        }
        return components.url ?? URL(string: "\(Self.scheme)://summary")!
    }

    /// Nil for anything that isn't a link this version understands.
    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        switch components.host?.lowercased() {
        case "summary":
            self = .summary
        case "history":
            self = .history
        case "song":
            let items = components.queryItems ?? []
            guard let title = items.first(where: { $0.name == "title" })?.value,
                  let artistName = items.first(where: { $0.name == "artist" })?.value
            else { return nil }
            self = .song(title: title, artistName: artistName)
        default:
            return nil
        }
    }
}
