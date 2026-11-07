import SwiftUI
import MusicKit
import TracksCore

/// What's known about an artist beyond your listening: what Apple Music's editors wrote about
/// them and the genre they're filed under. Only what's there: MusicKit has no hometown or
/// birthday, so neither is ever guessed at.
struct ArtistAbout: Equatable {
    var note: String?
    var genre: String?

    var isEmpty: Bool { note == nil && genre == nil }

    init(note: String?, genre: String?) {
        self.note = AboutNote.clean(note)
        self.genre = genre.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Apple Music's word on an artist: their biography, or the line about them where there's
    /// no biography, and their first genre that isn't the catch-all "Music". Nil when it has
    /// nothing to say.
    init?(_ artist: Artist) {
        let notes = artist.editorialNotes
        self.init(
            note: notes?.standard ?? notes?.short,
            genre: SongMetadata.primaryGenre(from: artist.genreNames ?? [])
        )
        if isEmpty { return nil }
    }
}

/// The About section near the foot of an artist's page, after the music and before your own
/// top songs by them: Apple Music's note on them, their genre, and when you first heard them.
struct AboutArtistSection: View {
    let name: String
    let about: ArtistAbout
    /// When you first played them, from the history. Nil for an artist new to you.
    var firstHeard: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ArtistSectionTitle(title: String(localized: "About \(name)")) { EmptyView() }
                .lineLimit(2)
            VStack(alignment: .leading, spacing: 16) {
                if let note = about.note {
                    AboutNote(title: name, text: note)
                }
                if !facts.isEmpty {
                    AboutFacts(facts: facts)
                }
            }
            .padding(Self.padding)
            .frame(maxWidth: Self.maximumWidth, alignment: .leading)
            .background(Color.cardFill, in: .rect(cornerRadius: Metrics.cardRadius, style: .continuous))
            .padding(.horizontal, PlayMetrics.margin)
        }
    }

    private var facts: [AboutFacts.Fact] {
        var facts: [AboutFacts.Fact] = []
        if let genre = about.genre {
            facts.append(.init(label: String(localized: "Genre"), value: genre))
        }
        if let firstHeard {
            facts.append(.init(label: String(localized: "First Heard"), value: firstHeard.formatted(.dateTime.month(.wide).year())))
        }
        return facts
    }

    #if os(macOS)
    private static let padding: CGFloat = 20
    /// A comfortable line of reading, not the width of a big window.
    private static let maximumWidth: CGFloat = 720
    #else
    private static let padding: CGFloat = 16
    private static let maximumWidth: CGFloat = .infinity
    #endif
}
