import SwiftUI
import TracksCore

/// A line naming a song's artists, with each name a link to that artist's page, as in Music.
///
/// The line is shown as written ("Umbra & Mara Solis", "Umbra x Mara Solis"), so nothing is
/// renamed; only the names it credits become links. Where nothing can push, it's plain text.
struct CreditedText: View {
    let text: String
    let credits: [ArtistCredit]
    var linkStyle: LinkStyle = .accent

    enum LinkStyle {
        /// Accent-coloured, for a page's header.
        case accent
        /// The line's own colour, for a row. On the Mac the names are underlined while the
        /// pointer is over them.
        case row
        /// A row's, in a Mac table's cell, where the table takes the clicks a link in text
        /// would get: each name is a button of its own.
        case cell
    }

    /// Where a name goes: your history's page for the artist, or their page in Apple Music.
    var destination: (ArtistCredit) -> PlayRoute = { .stats(.artist($0.identity)) }

    @Environment(\.openPlayRoute) private var openPlayRoute
    @State private var isHovering = false

    var body: some View {
        let linked = openPlayRoute.canPush ? Self.links(in: text, credits: credits) : []
        if linked.isEmpty {
            Text(verbatim: text)
        } else if linkStyle == .cell {
            cell(linked)
        } else {
            Text(Self.attributed(text, links: linked, underlined: linkStyle == .row && isHovering))
                .tint(linkStyle == .row ? AnyShapeStyle(.foreground) : nil)
                .onHover { isHovering = $0 }
                .environment(\.openURL, OpenURLAction { url in
                    guard let index = Self.index(of: url), linked.indices.contains(index) else { return .systemAction }
                    openPlayRoute(destination(linked[index].credit))
                    return .handled
                })
                // A row combines its children, so the names are offered as its actions.
                .accessibilityActions {
                    ForEach(linked.map { $0.credit }) { credit in
                        Button("Go to \(credit.name)") { openPlayRoute(destination(credit)) }
                    }
                }
        }
    }

    /// The names as buttons between the line's other words. When they don't fit, the first
    /// name stays a button and the rest of the line is cut short.
    private func cell(_ linked: [(credit: ArtistCredit, range: Range<String.Index>)]) -> some View {
        let pieces = Self.pieces(of: text, links: linked)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                ForEach(pieces.indices, id: \.self) { index in
                    piece(pieces[index])
                }
            }
            HStack(spacing: 0) {
                piece(pieces[0])
                    .layoutPriority(1)
                Text(verbatim: pieces.dropFirst().map(\.text).joined())
                    .truncationMode(.tail)
            }
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private func piece(_ piece: (text: String, credit: ArtistCredit?)) -> some View {
        if let credit = piece.credit {
            NameButton(name: piece.text) { openPlayRoute(destination(credit)) }
        } else {
            Text(verbatim: piece.text)
        }
    }

    /// The line cut at its names, so a name always starts a piece of its own.
    private static func pieces(of text: String, links: [(credit: ArtistCredit, range: Range<String.Index>)]) -> [(text: String, credit: ArtistCredit?)] {
        var pieces: [(text: String, credit: ArtistCredit?)] = []
        var cursor = text.startIndex
        for link in links {
            if cursor < link.range.lowerBound { pieces.append((String(text[cursor..<link.range.lowerBound]), nil)) }
            pieces.append((String(text[link.range]), link.credit))
            cursor = link.range.upperBound
        }
        if cursor < text.endIndex { pieces.append((String(text[cursor...]), nil)) }
        return pieces
    }

    /// Where each credited name is in `text`, in order, matched whole.
    static func links(in text: String, credits: [ArtistCredit]) -> [(credit: ArtistCredit, range: Range<String.Index>)] {
        var found: [(credit: ArtistCredit, range: Range<String.Index>)] = []
        for credit in credits {
            var searchStart = text.startIndex
            while let range = text.range(of: credit.name, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<text.endIndex) {
                let before = range.lowerBound == text.startIndex ? " " : text[text.index(before: range.lowerBound)]
                let after = range.upperBound == text.endIndex ? " " : text[range.upperBound]
                let isWhole = !before.isLetter && !before.isNumber && !after.isLetter && !after.isNumber
                if isWhole, !found.contains(where: { $0.range.overlaps(range) }) {
                    found.append((credit, range))
                    break
                }
                searchStart = range.upperBound
            }
        }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private static func attributed(_ text: String, links: [(credit: ArtistCredit, range: Range<String.Index>)], underlined: Bool) -> AttributedString {
        var result = AttributedString()
        var cursor = text.startIndex
        for (index, link) in links.enumerated() {
            result += AttributedString(text[cursor..<link.range.lowerBound])
            var name = AttributedString(text[link.range])
            name.link = URL(string: "tracks-credit:\(index)")
            if underlined { name.underlineStyle = .single }
            result += name
            cursor = link.range.upperBound
        }
        result += AttributedString(text[cursor...])
        return result
    }

    private static func index(of url: URL) -> Int? {
        guard url.scheme == "tracks-credit" else { return nil }
        return Int(url.absoluteString.dropFirst("tracks-credit:".count))
    }
}

/// One name in a table's cell, underlined under the pointer as a link is.
private struct NameButton: View {
    let name: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(verbatim: name)
                .underline(isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// A song's artist line in a list, each name opening their page in Apple Music.
struct ArtistLinks: View {
    /// The line, which can say more than the artist, like "Artist · Album".
    let text: String
    /// The song's artist, or nil for a line that doesn't name them.
    let artist: String?
    let title: String
    var linkStyle: CreditedText.LinkStyle = .row

    init(text: String? = nil, artist: String?, title: String, linkStyle: CreditedText.LinkStyle = .row) {
        self.text = text ?? artist ?? ""
        self.artist = artist
        self.title = title
        self.linkStyle = linkStyle
    }

    var body: some View {
        CreditedText(
            text: text,
            credits: artist.map { ArtistCredits.song(artist: $0, title: title) } ?? [],
            linkStyle: linkStyle,
            destination: { .artistNamed($0.name, identity: $0.identity) }
        )
    }
}
