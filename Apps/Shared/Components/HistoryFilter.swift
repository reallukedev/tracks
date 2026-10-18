import SwiftUI
import SwiftData
import TracksCore

enum HistoryFilter: String, CaseIterable, Identifiable {
    case all, radio, onDemand, recovered, lastFM

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .all: "All Songs"
        case .radio: "Radio"
        case .onDemand: "On Demand"
        case .recovered: "Recovered"
        case .lastFM: "From Last.fm"
        }
    }

    var symbol: String {
        switch self {
        case .all: "music.note.list"
        case .radio: "dot.radiowaves.left.and.right"
        case .onDemand: "music.note"
        case .recovered: "clock.arrow.circlepath"
        case .lastFM: "waveform"
        }
    }

    /// The plays a history list shows, filtered and sorted by the store rather than in
    /// memory, and at most `limit` of them.
    ///
    /// The lists used to query every play and filter and sort them in `body`. Sorting a
    /// hundred and fifty thousand plays by title took five seconds on the main actor.
    ///
    /// - Parameter source: Apple Music or Your Music only, when the person has asked to see
    ///   them apart. A play with no source is Apple Music's.
    func descriptor(
        sortBy: [SortDescriptor<Capture>] = [SortDescriptor(\.capturedAt, order: .reverse)],
        in interval: DateInterval? = nil,
        source: SourceScope = .all,
        limit: Int? = nil
    ) -> FetchDescriptor<Capture> {
        let kind = self.kind?.rawValue
        let start = interval?.start ?? .distantPast
        let end = interval?.end ?? .distantFuture
        let yourMusic: String? = PlaySource.yourMusic.rawValue
        var descriptor = FetchDescriptor<Capture>(sortBy: sortBy)
        // One predicate per shape rather than one with switches in it, so the store can use
        // the kind and date index for the lists that don't ask about the source.
        switch (kind, source) {
        case (let kind?, .all):
            descriptor.predicate = #Predicate {
                $0.kindRawValue == kind && $0.capturedAt >= start && $0.capturedAt < end
            }
        case (let kind?, .yourMusic):
            descriptor.predicate = #Predicate {
                $0.kindRawValue == kind && $0.capturedAt >= start && $0.capturedAt < end
                    && $0.sourceRawValue == yourMusic
            }
        case (let kind?, .appleMusic):
            descriptor.predicate = #Predicate {
                $0.kindRawValue == kind && $0.capturedAt >= start && $0.capturedAt < end
                    && ($0.sourceRawValue == nil || $0.sourceRawValue != yourMusic)
            }
        case (nil, .all):
            if interval != nil {
                descriptor.predicate = #Predicate { $0.capturedAt >= start && $0.capturedAt < end }
            }
        case (nil, .yourMusic):
            descriptor.predicate = #Predicate {
                $0.capturedAt >= start && $0.capturedAt < end && $0.sourceRawValue == yourMusic
            }
        case (nil, .appleMusic):
            descriptor.predicate = #Predicate {
                $0.capturedAt >= start && $0.capturedAt < end
                    && ($0.sourceRawValue == nil || $0.sourceRawValue != yourMusic)
            }
        }
        descriptor.fetchLimit = limit
        return descriptor
    }

    private var kind: CaptureKind? {
        switch self {
        case .all: nil
        case .radio: .radio
        case .onDemand: .onDemand
        case .recovered: .imported
        case .lastFM: .lastFM
        }
    }
}

/// How many plays a history list reads at a time. More are read as the end scrolls into view.
enum HistoryPage {
    static let size = 300
}
