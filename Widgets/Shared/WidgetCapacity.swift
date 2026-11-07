import WidgetKit
import TracksCore

/// The most songs each part of a widget could fit.
///
/// A ceiling: the views show as many whole rows as fit at the current text size (see
/// ``WidgetSongList``). The provider fetches no more than this, so it doesn't download
/// covers it can't draw, and the placeholder uses the same numbers.
struct WidgetCapacity: Sendable, Equatable {
    /// Rows of today's listening.
    let today: Int
    /// Rows of Up Next, or nil when the section is not shown at all.
    let upNext: Int?

    init(today: Int, upNext: Int?) {
        self.today = today
        self.upNext = upNext
    }

    /// Last Played only shows `lastPlayed`, which is always fetched.
    static let lastPlayed = WidgetCapacity(today: 0, upNext: nil)

    /// The Today widget's room for its size and whether Up Next is on.
    ///
    /// The numbers are what the largest device fits at the default text size. Large keeps a
    /// full Today with Up Next on, since an empty queue leaves Today most of the space.
    /// Medium splits in two with Up Next on, so its Today half needs one song.
    ///
    /// Keep these within `WidgetReading.mostTodayRows` and `mostUpNextRows`. The app only
    /// looks that far down when deciding whether to reload.
    static func today(family: WidgetFamily, showsUpNext: Bool) -> WidgetCapacity {
        let mostToday = WidgetReading.mostTodayRows
        let mostUpNext = WidgetReading.mostUpNextRows
        return switch (family, showsUpNext) {
        case (.systemLarge, true): WidgetCapacity(today: mostToday, upNext: mostUpNext)
        case (.systemLarge, false): WidgetCapacity(today: mostToday, upNext: nil)
        case (_, true): WidgetCapacity(today: 1, upNext: 3)
        case (_, false): WidgetCapacity(today: 3, upNext: nil)
        }
    }
}
