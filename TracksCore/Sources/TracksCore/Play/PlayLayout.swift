import Foundation

/// The Play tab's sections.
public enum PlaySection: String, CaseIterable, Sendable, Identifiable {
    /// The crate: this hour's mix, Tracks Radio, Discover and the rest of the day's mixes, to
    /// flip through. First, since it plays something good in one tap.
    case forYou
    /// Songs you've never played that Tracks thinks you'll like, led by Tracks Radio when the
    /// crate is hidden.
    case suggestedSongs
    /// Artists you've never played, like the ones you do.
    case suggestedArtists
    case recentlyPlayed
    /// The artists played most lately.
    case yourArtists
    case mixes
    case moods
    /// Pop, Hip-Hop, Rock and the rest, each with a page of its own, the ones you play first.
    case genres
    /// New albums and singles from the artists played most.
    case newReleases
    case radio
    /// Apple Music's charts.
    case charts
    case library
    /// Apple Music's own recommendations.
    case appleMusic

    public var id: String { rawValue }
}

/// Which sections the Play tab shows, in what order. The person's to arrange.
public struct PlayLayout: Sendable, Equatable {
    /// Every section, in the order chosen, hidden ones included so they keep their place.
    public private(set) var order: [PlaySection]
    public private(set) var hidden: Set<PlaySection>

    public static let standard = PlayLayout(order: PlaySection.allCases, hidden: [])

    public init(order: [PlaySection], hidden: Set<PlaySection>) {
        self.order = order
        self.hidden = hidden
        normalize()
    }

    public var visible: [PlaySection] {
        order.filter { !hidden.contains($0) }
    }

    public func isVisible(_ section: PlaySection) -> Bool {
        !hidden.contains(section)
    }

    public mutating func setVisible(_ section: PlaySection, _ isVisible: Bool) {
        if isVisible { hidden.remove(section) } else { hidden.insert(section) }
    }

    /// For a switch bound straight to one section.
    public subscript(isVisible section: PlaySection) -> Bool {
        get { isVisible(section) }
        set { setVisible(section, newValue) }
    }

    public mutating func move(from offsets: IndexSet, to destination: Int) {
        // `IndexSet` moves the way List reports them: remove, then insert before `destination`.
        let moving = offsets.map { order[$0] }
        var rest = order.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        let insertAt = destination - offsets.count { $0 < destination }
        rest.insert(contentsOf: moving, at: min(max(0, insertAt), rest.count))
        order = rest
    }

    /// Every section exactly once. Ones added in an update go where they sit by default, after
    /// the section that comes before them there.
    private mutating func normalize() {
        var seen = Set<PlaySection>()
        var result = order.filter { seen.insert($0).inserted }
        for (index, section) in PlaySection.allCases.enumerated() where !seen.contains(section) {
            let before = PlaySection.allCases[..<index].last { result.contains($0) }
            let position = before.flatMap { result.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            result.insert(section, at: position)
        }
        order = result
    }

    // MARK: - Storage

    /// As text, for a defaults key: "radio,forYou,-library" (a minus means hidden). Unknown
    /// names, from a newer version, are dropped.
    public var stored: String {
        order.map { hidden.contains($0) ? "-\($0.rawValue)" : $0.rawValue }.joined(separator: ",")
    }

    public init(stored: String) {
        guard !stored.isEmpty else {
            self = .standard
            return
        }
        var order: [PlaySection] = []
        var hidden = Set<PlaySection>()
        for part in stored.split(separator: ",") {
            let isHidden = part.hasPrefix("-")
            guard let section = PlaySection(rawValue: String(isHidden ? part.dropFirst() : part)) else { continue }
            order.append(section)
            if isHidden { hidden.insert(section) }
        }
        self.init(order: order, hidden: hidden)
    }
}
