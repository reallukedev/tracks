import Foundation

/// Where each record in Play's crate sits, as Cover Flow laid out its albums: the one in front,
/// the first either side tucked just behind it, and each one after that the same step further
/// out, a little smaller and darker, crisp all the way. As many as fit the width show; the
/// next one out fades as it comes or goes, so there's never a record half there at rest.
///
/// Distances are in records from the front (`a`, never negative) and in covers across.
public enum CrateFan {
    /// How far a record sits from the front's centre, in covers, `a` records out.
    ///
    /// The one in front and the one beside it swap which is on top halfway between their
    /// places, and a swap where they overlap shows as one cutting into the other. So on the
    /// way to the front a record moves out of the way a little quicker at first, as Cover
    /// Flow's did: halfway, the two stand clear of each other and the swap can't be seen.
    public static func reach(_ a: Double) -> Double {
        let near = min(a, 1)
        return 0.86 * (near + inner * near * (1 - near)) + max(0, a - 1) * step
    }

    /// How much quicker the first step out is than an even one.
    static let inner = 0.4

    /// How large a record is, `a` records out, the front's size being 1.
    public static func scale(_ a: Double) -> Double {
        max(0.5, 1 - 0.14 * min(a, 1) - 0.07 * max(0, a - 1))
    }

    /// Each record past the first beside the front, in covers.
    public static let step = 0.34

    /// The most records a side ever shows, however wide the crate.
    public static let deepest = 12

    /// How many records a side fit in this width, the front's included in none: at least one,
    /// the one beside the front, which may run under the edge's fade.
    public static func depth(width: Double, side: Double) -> Double {
        guard side > 0 else { return 1 }
        // Inside the fade at either edge.
        let room = width / 2 * 0.91
        var count = 1
        while count < deepest {
            let next = Double(count + 1)
            guard (reach(next) + scale(next) / 2) * side <= room else { break }
            count += 1
        }
        return Double(count)
    }
}

/// Where the crate is scrolled to, in records: the place passing through its middle, and
/// whether it's pulled past the first or the last.
public struct CratePosition: Equatable, Sendable {
    /// The place in the row in the middle, from 0 for the first; held to the row at the ends.
    public let place: Int
    /// Whether the crate is pulled beyond its first or last record, rubber-banding.
    public let isPastEnd: Bool
    /// How many places the row has. Part of the position, so records added before the one in
    /// the middle, which move it along without moving the scroll, count as a change.
    public let places: Int
    /// Whether the crate is resting between records rather than with one in the middle: a
    /// scroll that stops less than half a record from one still has `place` on it.
    public let isBetween: Bool

    /// How far from a record's place, in points, still counts as on it.
    public static let tolerance = 0.5

    /// How far past an end the crate is pulled, in records, before it counts: a hair, so the
    /// end is felt as it gives, not on the way to settling at it.
    public static let endGive = 0.12

    /// - Parameters:
    ///   - offset: How far the first place's centre has scrolled past the middle, as the
    ///     scroll view reports it: from its inset's edge.
    ///   - inset: The scroll view's leading content inset, which `offset` leaves out: the
    ///     Mac's sidebar over the crate, or an iPhone's safe area on its side.
    ///   - pitch: From one record's place to the next.
    ///   - places: How many places the row has.
    public init(offset: Double, inset: Double = 0, pitch: Double, places: Int) {
        self.places = places
        guard pitch > 0, places > 0, offset.isFinite, inset.isFinite else {
            place = 0
            isPastEnd = false
            isBetween = false
            return
        }
        let position = (offset + inset) / pitch
        let last = Double(places - 1)
        let held = min(max(position, 0), last)
        place = Int(held.rounded())
        isPastEnd = position < -Self.endGive || position > last + Self.endGive
        isBetween = abs(held - Double(place)) * pitch > Self.tolerance
    }
}

/// Where the crate comes to rest after a scroll by hand: with a record in the middle. A flick
/// riffles through a few; a slow drag moves them one at a time.
public enum CrateRest {
    /// The most records a single flick carries the crate.
    public static let flingReach = 4

    /// Where a scroll heading for `proposed` settles.
    ///
    /// - Parameters:
    ///   - proposed: Where the scroll would stop on its own, as an offset.
    ///   - inset: The scroll view's leading content inset, which offsets leave out, as they
    ///     do for ``CratePosition``.
    ///   - start: The place in the middle as the scroll began, which it goes no more than
    ///     ``flingReach`` from; nil for no limit.
    ///   - pitch: From one record's place to the next.
    ///   - last: How far the last record's place is from the first's.
    /// - Returns: The offset that puts the nearest record in the middle.
    public static func offset(for proposed: Double, inset: Double = 0, from start: Int?, pitch: Double, last: Double) -> Double {
        guard pitch > 0, proposed.isFinite, inset.isFinite else { return proposed }
        var place = Int(((proposed + inset) / pitch).rounded())
        if let start {
            place = min(max(place, start - flingReach), start + flingReach)
        }
        let lastPlace = Int((max(0, last) / pitch).rounded())
        return Double(min(max(place, 0), lastPlace)) * pitch - inset
    }
}

/// The crate's row, place by place: the quiet record at the start while more songs are looked
/// for, the records, and the quiet one at the end. The crate is scrolled by place, and chooses
/// by record.
public struct CrateRow: Equatable, Sendable {
    public enum Slot: Equatable, Sendable {
        case leadingEnd
        /// The record at this index among the records.
        case record(Int)
        case trailingEnd
    }

    public let records: Int
    public let hasLeadingEnd: Bool
    public let hasTrailingEnd: Bool

    public init(records: Int, hasLeadingEnd: Bool, hasTrailingEnd: Bool) {
        self.records = max(0, records)
        self.hasLeadingEnd = hasLeadingEnd
        self.hasTrailingEnd = hasTrailingEnd
    }

    /// How many places the row has, the quiet records included.
    public var places: Int { records + (hasLeadingEnd ? 1 : 0) + (hasTrailingEnd ? 1 : 0) }

    /// What's at a place, or nil for one outside the row.
    public func slot(at place: Int) -> Slot? {
        let index = place - (hasLeadingEnd ? 1 : 0)
        if (0..<records).contains(index) { return .record(index) }
        if index == -1, hasLeadingEnd { return .leadingEnd }
        if index == records, hasTrailingEnd { return .trailingEnd }
        return nil
    }

    /// Where something is in the row, or nil when it isn't there.
    public func place(of slot: Slot) -> Int? {
        switch slot {
        case .leadingEnd:
            return hasLeadingEnd ? 0 : nil
        case .record(let index):
            return (0..<records).contains(index) ? index + (hasLeadingEnd ? 1 : 0) : nil
        case .trailingEnd:
            return hasTrailingEnd ? records + (hasLeadingEnd ? 1 : 0) : nil
        }
    }
}

/// How the crate moves under a trackpad on the Mac, where it follows the fingers itself
/// rather than riding a scroll view: places are records, and the first is 0.
public enum CrateFling {
    /// A position pulled past either end gives less the further it goes, as a scroll view's
    /// edge does, and never more than half a record.
    public static func banded(_ raw: Double, last: Double) -> Double {
        let last = max(0, last)
        if raw < 0 { return -band(-raw) }
        if raw > last { return last + band(raw - last) }
        return raw
    }

    private static func band(_ over: Double) -> Double {
        0.5 * (1 - 1 / (over * 1.6 + 1))
    }

    /// Where a flick lets go and comes to rest: carried on by its speed, in records a second,
    /// for about a quarter of a second, then onto the nearest record within the row.
    public static func target(from position: Double, velocity: Double, last: Int) -> Int {
        guard position.isFinite, velocity.isFinite, last >= 0 else { return 0 }
        let carried = position + max(-40, min(40, velocity)) * 0.24
        return min(max(0, Int(carried.rounded())), last)
    }
}
