import Foundation

public enum MusicBrainzError: Error, Equatable {
    /// MusicBrainz turned the request away for coming too soon, twice.
    case busy
    case http(status: Int)
    case malformedResponse
}

/// Spaces requests to MusicBrainz, which asks for no more than one a second from a client.
public actor MusicBrainzGate {
    public static let shared = MusicBrainzGate(spacing: .milliseconds(1_100))

    private let spacing: Duration
    private var next = ContinuousClock.now

    public init(spacing: Duration) {
        self.spacing = spacing
    }

    /// Waits for this request's turn. The slot is taken before the wait, so two callers
    /// arriving together are spaced rather than let through at once.
    public func turn() async throws {
        let start = max(ContinuousClock.now, next)
        next = start.advanced(by: spacing)
        try await Task.sleep(until: start, clock: .continuous)
    }
}

/// Reads credits and samples from MusicBrainz, the open music encyclopedia. Free, keyless and
/// read only; it asks for an identifying User-Agent and a request a second.
public struct MusicBrainzClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let base = URL(string: "https://musicbrainz.org/ws/2/")!
    static let includes = "artist-credits+artist-rels+recording-rels+work-rels+work-level-rels+genres"

    let userAgent: String
    let gate: MusicBrainzGate
    let transport: Transport
    let retryDelay: Duration

    public init(
        userAgent: String,
        gate: MusicBrainzGate = .shared,
        retryDelay: Duration = .seconds(2),
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }
    ) {
        self.userAgent = userAgent
        self.gate = gate
        self.retryDelay = retryDelay
        self.transport = transport
    }

    /// The recording's credits and samples, found by its ISRC, or by its exact title and
    /// artist when it has none. Nil when MusicBrainz doesn't know it.
    ///
    /// One ISRC can lead to a few recordings, the same song entered more than once, and its
    /// credits may sit on any of them, so the first few are read together.
    public func credits(isrc: String?, title: String, artistName: String, duration: TimeInterval?) async throws -> SongCredits? {
        let recordingIDs: [String]
        if let isrc, !isrc.isEmpty {
            recordingIDs = try await recordings(isrc: isrc)
        } else {
            recordingIDs = try await search(title: title, artistName: artistName, duration: duration).map { [$0] } ?? []
        }
        var found: [[String: Any]] = []
        for id in recordingIDs.prefix(Self.recordingsRead) {
            if let json = try await get("recording/\(id)", query: ["inc": Self.includes]) { found.append(json) }
        }
        return Self.credits(from: Self.combined(found))
    }

    /// Other recordings of the song's composition, and its key where the composition has one.
    /// - Parameter excluding: the song's own recordings, which aren't other versions of it.
    public func versions(workID: String, title: String, artistName: String, excluding: Set<String>) async throws -> SongVersions? {
        guard let json = try await get("work/\(workID)", query: ["inc": "recording-rels+artist-credits"]) else { return nil }
        return Self.versions(from: json, title: title, artistName: artistName, excluding: excluding)
    }

    /// Recordings read for one ISRC: a duplicate or two is common, a dozen isn't the same song.
    static let recordingsRead = 3

    func recordings(isrc: String) async throws -> [String] {
        let json = try await get("isrc/\(isrc.uppercased())", query: [:])
        let recordings = json?["recordings"] as? [[String: Any]] ?? []
        return recordings.compactMap { $0["id"] as? String }
    }

    /// Several entries for one recording read as one: every relationship, the earliest
    /// release, the first's id.
    static func combined(_ recordings: [[String: Any]]) -> [String: Any]? {
        guard var first = recordings.first else { return nil }
        guard recordings.count > 1 else { return first }
        first["relations"] = recordings.flatMap { $0["relations"] as? [[String: Any]] ?? [] }
        first["genres"] = recordings.flatMap { $0["genres"] as? [[String: Any]] ?? [] }
        first["first-release-date"] = recordings.compactMap { $0["first-release-date"] as? String }.filter { !$0.isEmpty }.min()
        return first
    }

    func search(title: String, artistName: String, duration: TimeInterval?) async throws -> String? {
        let query = "recording:\"\(Self.escaped(title))\" AND artist:\"\(Self.escaped(artistName))\""
        let json = try await get("recording", query: ["query": query, "limit": "10"])
        let recordings = json?["recordings"] as? [[String: Any]] ?? []
        return Self.exactMatch(in: recordings, title: title, artistName: artistName, duration: duration)
    }

    /// The first result with the same title and artist, ignoring case and accents, and a
    /// length within a few seconds where both are known. A near miss isn't the song.
    static func exactMatch(in recordings: [[String: Any]], title: String, artistName: String, duration: TimeInterval?) -> String? {
        let wantedTitle = folded(title)
        let wantedArtist = folded(artistName)
        return recordings.first { recording in
            guard let name = recording["title"] as? String, folded(name) == wantedTitle,
                  folded(artistCredit(recording["artist-credit"])) == wantedArtist
            else { return false }
            if let duration, let length = recording["length"] as? Double {
                return abs(length / 1_000 - duration) <= 4
            }
            return true
        }?["id"] as? String
    }

    // MARK: - Reading a recording

    static func credits(from json: [String: Any]?) -> SongCredits? {
        guard let json, let id = json["id"] as? String else { return nil }
        var builder = CreditsBuilder()
        var credits = SongCredits(recordingID: id)

        for relation in json["relations"] as? [[String: Any]] ?? [] {
            let type = relation["type"] as? String ?? ""
            let attributes = relation["attributes"] as? [String] ?? []
            let isBackward = relation["direction"] as? String == "backward"
            switch relation["target-type"] as? String {
            case "artist":
                guard let name = (relation["artist"] as? [String: Any])?["name"] as? String,
                      let role = recordingRole(type, attributes: attributes)
                else { continue }
                builder.add(name, role)
            case "recording":
                guard let target = relation["recording"] as? [String: Any], let link = recordingLink(target) else { continue }
                switch (type, isBackward) {
                case ("samples material", false): append(link, to: &credits.samples)
                case ("samples material", true): append(link, to: &credits.sampledBy)
                case ("mashes up", true): append(link, to: &credits.mashups)
                case ("remix", true): append(link, to: &credits.remixes)
                default: continue
                }
            case "work":
                guard type == "performance", let work = relation["work"] as? [String: Any] else { continue }
                if let workID = work["id"] as? String, !credits.workIDs.contains(workID) {
                    credits.workIDs.append(workID)
                }
                for writer in work["relations"] as? [[String: Any]] ?? [] {
                    guard writer["target-type"] as? String == "artist",
                          let name = (writer["artist"] as? [String: Any])?["name"] as? String,
                          let role = workRole(writer["type"] as? String ?? "")
                    else { continue }
                    builder.add(name, role)
                }
            default:
                continue
            }
        }
        credits.sections = builder.sections
        credits.genres = genres(json["genres"])
        credits.firstReleaseYear = year(json["first-release-date"])
        return credits
    }

    private static func append(_ link: RecordingLink, to links: inout [RecordingLink]) {
        if !links.contains(where: { $0.recordingID == link.recordingID }) { links.append(link) }
    }

    /// Genre names by how many people gave them, each once.
    static func genres(_ value: Any?) -> [String] {
        var votes: [String: Int] = [:]
        var order: [String] = []
        for genre in value as? [[String: Any]] ?? [] {
            guard let name = genre["name"] as? String, !name.isEmpty else { continue }
            if votes[name] == nil { order.append(name) }
            votes[name, default: 0] += genre["count"] as? Int ?? 0
        }
        return order.enumerated()
            .sorted { (votes[$0.element]!, -$0.offset) > (votes[$1.element]!, -$1.offset) }
            .map(\.element)
    }

    static func year(_ value: Any?) -> Int? {
        (value as? String).flatMap { Int($0.prefix(4)) }
    }

    // MARK: - Reading a work

    /// Words in MusicBrainz's note that mark a recording as the same take sold another way
    /// rather than a version worth listing: an edit, a clean copy, a DJ's mix.
    static let sameTakeNotes = ["clean", "explicit", "edit", "album version", "radio", "dj mix", "karaoke", "call out", "snippet"]
    /// The same, in a title, where a word like "radio" may be the song's own name.
    static let sameTakeTitles = ["karaoke", "radio edit", "clean version", "dj mix"]

    /// Whole words only, so "edit" doesn't catch "Meditation".
    static func mentions(_ text: String, _ phrases: [String]) -> Bool {
        let text = " \(words(text)) "
        return phrases.contains { phrase in
            let phrase = words(phrase)
            return !phrase.isEmpty && text.contains(" \(phrase) ")
        }
    }

    /// Folded, with anything but letters and digits as single spaces.
    private static func words(_ text: String) -> String {
        String(folded(text).map { $0.isLetter || $0.isNumber ? $0 : " " }).split(separator: " ").joined(separator: " ")
    }

    static func versions(from json: [String: Any], title: String, artistName: String, excluding: Set<String>) -> SongVersions {
        var versions: [RecordingLink] = []
        var covers: [RecordingLink] = []
        var coverArtists: [String: Int] = [:]
        var seenVersions: Set<String> = []
        let song = folded(title)

        for relation in json["relations"] as? [[String: Any]] ?? [] {
            guard relation["type"] as? String == "performance",
                  relation["target-type"] as? String == "recording",
                  let recording = relation["recording"] as? [String: Any],
                  let id = recording["id"] as? String, !excluding.contains(id),
                  let name = recording["title"] as? String, !name.isEmpty
            else { continue }
            let attributes = relation["attributes"] as? [String] ?? []
            let note = (recording["disambiguation"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !attributes.contains("karaoke"), !mentions(note, sameTakeNotes), !mentions(name, sameTakeTitles) else { continue }
            let noteKey = folded(note)
            let titleKey = folded(name)

            let credit = artistCredit(recording["artist-credit"])
            let creditKey = folded(credit)
            // "Kanye West feat. Jamie Foxx" is Kanye West's own, but "Ye" isn't inside "Kanye".
            let isOwn = !creditKey.isEmpty && (mentions(credit, [artistName]) || mentions(artistName, [credit]))
            let link = RecordingLink(
                title: name,
                artistName: credit,
                year: year(recording["first-release-date"]),
                detail: describe(note: note, attributes: attributes),
                recordingID: id
            )
            if attributes.contains("cover") || !isOwn {
                guard !creditKey.isEmpty else { continue }
                // One per artist, a studio take over a live one.
                if let index = coverArtists[creditKey] {
                    if attributes.contains("live") == false, covers[index].detail?.localizedCaseInsensitiveContains("live") == true {
                        covers[index] = link
                    }
                } else {
                    coverArtists[creditKey] = covers.count
                    covers.append(link)
                }
            } else {
                // The same song on another release is the song, not a version of it.
                if titleKey == song, note.isEmpty, attributes.isEmpty { continue }
                guard seenVersions.insert("\(titleKey)|\(noteKey)").inserted else { continue }
                versions.append(link)
            }
        }

        let key = (json["attributes"] as? [[String: Any]] ?? []).first { ($0["type"] as? String) == "Key" }?["value"] as? String
        return SongVersions(versions: versions, covers: covers, key: key.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// MusicBrainz's note with a capital, or the kind of performance where there's no note.
    static func describe(note: String, attributes: [String]) -> String? {
        if !note.isEmpty { return note.prefix(1).uppercased() + note.dropFirst() }
        let words: [(String, String)] = [
            ("live", String(localized: "Live")),
            ("acoustic", String(localized: "Acoustic")),
            ("instrumental", String(localized: "Instrumental")),
            ("medley", String(localized: "Medley")),
            ("partial", String(localized: "Partial")),
        ]
        let found = words.filter { attributes.contains($0.0) }.map(\.1)
        return found.isEmpty ? nil : found.formatted(.list(type: .and, width: .narrow))
    }

    static func recordingRole(_ type: String, attributes: [String]) -> CreditRole? {
        let detail = attributes.first
        return switch type {
        case "performer": attributes.contains("guest") ? CreditRole(.featured) : CreditRole(.performer)
        case "vocal": CreditRole(.vocals, detail: detail)
        case "instrument": CreditRole(.instrument, detail: detail)
        case "performing orchestra": CreditRole(.orchestra)
        case "conductor": CreditRole(.conductor)
        case "producer": CreditRole(.producer, detail: detail)
        case "mix": CreditRole(.mixing)
        case "engineer", "audio", "sound": CreditRole(.engineer, detail: detail)
        case "recording": CreditRole(.recording)
        case "mastering": CreditRole(.mastering)
        case "programming": CreditRole(.programming)
        case "arranger", "instrument arranger", "vocal arranger": CreditRole(.arranger)
        case "writer", "composer", "lyricist": workRole(type)
        default: nil
        }
    }

    static func workRole(_ type: String) -> CreditRole? {
        switch type {
        case "writer": CreditRole(.songwriter)
        case "composer": CreditRole(.composer)
        case "lyricist": CreditRole(.lyricist)
        case "arranger": CreditRole(.arranger)
        default: nil
        }
    }

    static func recordingLink(_ recording: [String: Any]) -> RecordingLink? {
        guard let id = recording["id"] as? String,
              let title = recording["title"] as? String, !title.isEmpty
        else { return nil }
        return RecordingLink(title: title, artistName: artistCredit(recording["artist-credit"]), year: year(recording["first-release-date"]), recordingID: id)
    }

    /// "Kanye West feat. Jamie Foxx", put back together from MusicBrainz's credit parts.
    static func artistCredit(_ value: Any?) -> String {
        let parts = value as? [[String: Any]] ?? []
        return parts.map { part in
            (part["name"] as? String ?? "") + (part["joinphrase"] as? String ?? "")
        }.joined().trimmingCharacters(in: .whitespaces)
    }

    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Lucene's quote and backslash, so a title can't end the phrase early.
    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Transport

    /// Nil for a 404, which is MusicBrainz saying it doesn't know the thing.
    private func get(_ path: String, query: [String: String]) async throws -> [String: Any]? {
        var components = URLComponents(url: Self.base.appending(path: path), resolvingAgainstBaseURL: false)
        components?.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            + [URLQueryItem(name: "fmt", value: "json")]
        guard let url = components?.url else { throw MusicBrainzError.malformedResponse }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        for attempt in 0..<2 {
            try await gate.turn()
            let (data, response) = try await transport(request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            switch status {
            case 200..<300:
                guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    throw MusicBrainzError.malformedResponse
                }
                return json
            case 404:
                return nil
            case 429, 503:
                if attempt == 0 { try await Task.sleep(for: retryDelay) }
            default:
                throw MusicBrainzError.http(status: status)
            }
        }
        throw MusicBrainzError.busy
    }
}

/// Gathers each person once per group, with every role they had in it.
private struct CreditsBuilder {
    private var groups: [CreditSection.Kind: [Credit]] = [:]

    mutating func add(_ name: String, _ role: CreditRole) {
        let kind = Self.section(of: role.kind)
        var credits = groups[kind, default: []]
        if let index = credits.firstIndex(where: { $0.name == name }) {
            if !credits[index].roles.contains(role) { credits[index].roles.append(role) }
        } else {
            credits.append(Credit(name: name, roles: [role]))
        }
        groups[kind] = credits
    }

    var sections: [CreditSection] {
        CreditSection.Kind.allCases.compactMap { kind in
            groups[kind].map { CreditSection(kind: kind, credits: $0) }
        }
    }

    static func section(of kind: CreditRole.Kind) -> CreditSection.Kind {
        switch kind {
        case .featured, .performer, .vocals, .instrument, .orchestra, .conductor: .performers
        case .songwriter, .composer, .lyricist, .arranger: .composition
        case .producer, .mixing, .engineer, .recording, .mastering, .programming: .production
        }
    }
}
