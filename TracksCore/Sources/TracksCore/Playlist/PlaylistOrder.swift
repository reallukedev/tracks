import Foundation

/// The order a playlist's songs are shown and played in: the playlist's own, the other way
/// round, or by a name or your plays as the library sorts. A playlist keeps songs in the order
/// they were added, and Favorite Songs in the order they were liked, so the other way round
/// is the newest first.
public enum PlaylistOrder: Hashable, Sendable, RawRepresentable {
    case playlist
    case newestFirst
    case library(LibraryOrder)

    public init?(rawValue: String) {
        switch rawValue {
        case "playlist": self = .playlist
        case "newestFirst": self = .newestFirst
        default:
            guard let order = LibraryOrder(rawValue: rawValue) else { return nil }
            self = .library(order)
        }
    }

    public var rawValue: String {
        switch self {
        case .playlist: "playlist"
        case .newestFirst: "newestFirst"
        case .library(let order): order.rawValue
        }
    }

    /// Whether every song has to be there before the order means anything: only the
    /// playlist's own order can show its first page before the rest arrives.
    public var needsEverySong: Bool { self != .playlist }

    /// The items in this order. Songs the order can't tell apart keep the playlist's order.
    /// `listedNewestFirst` says the playlist's own order already has the newest at the top, as
    /// Favorite Songs does on iPhone, where it's the other way round on the Mac.
    public func sorted<Item>(_ items: [Item], listedNewestFirst: Bool = false, keys: (Item) -> LibrarySortKeys) -> [Item] {
        switch self {
        case .playlist: items
        case .newestFirst: listedNewestFirst ? items : items.reversed()
        case .library(let order): LibrarySort.sorted(items, by: order, keys: keys)
        }
    }

    /// Whether songs listed in this order were added newest first: more of them follow one added
    /// later than one added earlier. Unknown dates don't count; with none known, it's not.
    public static func isNewestFirst(added dates: [Date?]) -> Bool {
        let known = dates.compactMap(\.self)
        guard known.count > 1 else { return false }
        let steps = zip(known, known.dropFirst())
        let back = steps.filter { $0 > $1 }.count, forward = steps.filter { $0 < $1 }.count
        return back > forward
    }
}
