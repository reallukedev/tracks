import SwiftUI
import MusicKit
import TracksCore

/// What's known about a song beyond your listening, as Music's footer tells you about a
/// record: when it came out, its genre, who wrote it, how long it is, how it's mastered, and
/// whose recording it is. Only what's there, never a blank row.
struct SongAbout: Equatable {
    /// How it's mastered, as Apple Music badges a song.
    enum Quality: Equatable {
        case lossless, hiResLossless, dolbyAtmos

        var label: String {
            switch self {
            case .lossless: String(localized: "Lossless")
            case .hiResLossless: String(localized: "Hi-Res Lossless")
            case .dolbyAtmos: String(localized: "Dolby Atmos")
            }
        }

        var symbol: String {
            switch self {
            case .lossless, .hiResLossless: "waveform"
            case .dolbyAtmos: "hifispeaker.2.fill"
            }
        }
    }

    var note: String?
    var released: Date?
    /// For a song known only by its year: a file's tags, or the history's lookup.
    var year: Int?
    var genre: String?
    var composer: String?
    var length: TimeInterval?
    var qualities: [Quality] = []
    /// A file of your own: its codec and resolution.
    var format: AudioFormat?
    var recordLabel: String?
    /// "℗ 2005 Roc-A-Fella Records, LLC", as the album gives it.
    var copyright: String?
    var isrc: String?
    /// Whether Apple Music has its lyrics. Nil where nobody's said.
    var hasLyrics: Bool?
    var isExplicit = false
    var albumTitle: String?
    var trackNumber: Int?
    /// The album's songs, for "4 of 12".
    var trackCount: Int?

    /// Apple Music gives a release as a day, at midnight UTC: read anywhere else, it would be
    /// the day before west of Greenwich.
    static let releaseDateStyle = Date.FormatStyle(date: .long, time: .omitted, timeZone: .gmt)

    var releaseYear: Int? {
        released.map { Calendar(identifier: .gregorian).dateComponents(in: .gmt, from: $0).year } ?? nil
    }

    var hasFacts: Bool {
        released != nil || year != nil || genre != nil || composer != nil || (length ?? 0) > 0
            || recordLabel != nil || copyright != nil || isrc != nil
    }
}

extension SongAbout {
    /// Apple Music's word on a song, with its album's label and copyright where the album
    /// came with it.
    init(song: Song) {
        note = AboutNote.clean(song.editorialNotes?.standard ?? song.editorialNotes?.short)
        released = song.releaseDate
        genre = SongMetadata.primaryGenre(from: song.genreNames)
        composer = Self.nonEmpty(song.composerName)
        length = song.duration
        qualities = Self.qualities(song.audioVariants ?? [])
        isrc = Self.nonEmpty(song.isrc)
        hasLyrics = song.hasLyrics
        isExplicit = song.contentRating == .explicit
        albumTitle = Self.nonEmpty(song.albumTitle)
        trackNumber = song.trackNumber
        if let album = song.albums?.first {
            recordLabel = Self.nonEmpty(album.recordLabelName)
            copyright = Self.nonEmpty(album.copyright)
            trackCount = album.trackCount > 0 ? album.trackCount : nil
        }
    }

    /// A song of yours: what its file's tags or its server say.
    init(track: LocalTrack) {
        year = track.year
        genre = Self.nonEmpty(track.genre)
        length = track.duration
        format = track.format
        albumTitle = Self.nonEmpty(track.album)
        trackNumber = track.trackNumber
    }

    /// Hi-Res Lossless in place of Lossless, and Dolby Atmos, in the order Music shows them.
    static func qualities(_ variants: [AudioVariant]) -> [Quality] {
        var qualities: [Quality] = []
        if variants.contains(.highResolutionLossless) {
            qualities.append(.hiResLossless)
        } else if variants.contains(.lossless) {
            qualities.append(.lossless)
        }
        if variants.contains(.dolbyAtmos) {
            qualities.append(.dolbyAtmos)
        }
        return qualities
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// "Lossless", "Dolby Atmos": a song's small grey badge, drawn as a song of your own shows its
/// format.
struct AboutQualityBadge: View {
    let label: String
    let symbol: String

    init(quality: SongAbout.Quality) {
        label = quality.label
        symbol = quality.symbol
    }

    init(label: String, symbol: String) {
        self.label = label
        self.symbol = symbol
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption2.weight(.bold))
            Text(label)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(.secondary)
        .background(Color(.tertiarySystemFill), in: .capsule)
        .accessibilityElement(children: .combine)
    }
}
