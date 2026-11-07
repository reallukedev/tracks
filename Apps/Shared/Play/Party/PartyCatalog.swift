import Foundation
import MusicKit
import TracksCore

/// Apple Music's playlists and stations for a party, found by searching for each of its terms
/// and ranked by ``PartyPlaylistRanking``.
enum PartyCatalog {
    struct Found {
        /// Best first: the first is the Top Pick.
        var playlists: [Playlist]
        var stations: [FeedItem]
    }

    enum Outcome {
        case found(Found)
        /// Every search failed: offline, or Apple Music out of reach.
        case failed
    }

    /// Enough to choose from without a wall of covers.
    static let playlistLimit = 13

    static func find(_ vibe: PartyVibe, isDemo: Bool, allowsExplicit: Bool) async -> Outcome {
        #if DEBUG
        if isDemo { return await PartyDemo.find(vibe) }
        #endif
        guard !isDemo else { return .found(Found(playlists: [], stations: [])) }
        let results = await search(vibe.searchTerms)
        guard !Task.isCancelled else { return .found(Found(playlists: [], stations: [])) }
        let answered = results.compactMap(\.self)
        guard !answered.isEmpty else { return .failed }

        let byID = Dictionary(answered.flatMap(\.playlists).map { ($0.id.rawValue, $0) }, uniquingKeysWith: { first, _ in first })
        let ranked = PartyPlaylistRanking.rank(
            answered.map { $0.playlists.map(candidate) },
            for: vibe,
            allowsExplicit: allowsExplicit
        )
        var seenStations = Set<MusicItemID>()
        let stations = answered.flatMap(\.stations).filter { seenStations.insert($0.id).inserted }
        return .found(Found(
            playlists: ranked.prefix(playlistLimit).compactMap { byID[$0.id] },
            stations: stations.prefix(6).map { FeedItem(station: $0) }
        ))
    }

    private static func candidate(_ playlist: Playlist) -> PartyPlaylistCandidate {
        PartyPlaylistCandidate(
            id: playlist.id.rawValue,
            name: playlist.name,
            isAppleCurated: playlist.kind == .editorial || playlist.curatorName?.contains("Apple Music") == true
        )
    }

    /// One search per term, all at once. Nil where a search failed.
    @concurrent
    nonisolated private static func search(_ terms: [String]) async -> [(playlists: [Playlist], stations: [MusicKit.Station])?] {
        await withTaskGroup(of: (Int, (playlists: [Playlist], stations: [MusicKit.Station])?).self) { group in
            for (index, term) in terms.enumerated() {
                group.addTask {
                    var request = MusicCatalogSearchRequest(term: term, types: [Playlist.self, MusicKit.Station.self])
                    request.limit = 15
                    guard let response = try? await request.response() else { return (index, nil) }
                    return (index, (Array(response.playlists), Array(response.stations)))
                }
            }
            var byIndex: [Int: (playlists: [Playlist], stations: [MusicKit.Station])?] = [:]
            for await (index, result) in group { byIndex[index] = result }
            return terms.indices.map { byIndex[$0] ?? nil }
        }
    }
}

extension Playlist {
    /// Apple Music's words on the playlist, short where there's a short version.
    var partyNote: String? {
        guard let note = (shortDescription ?? standardDescription)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !note.isEmpty
        else { return nil }
        return note
    }
}

#if DEBUG
/// Invented Apple Music playlists for each party, made from API JSON, so the page shows full
/// with sample data. Every name and description here is made up.
enum PartyDemo {
    static func find(_ vibe: PartyVibe) async -> PartyCatalog.Outcome {
        // A moment's wait, as a search takes; `-TracksPartyDelay 60` holds the loading state
        // for a screenshot.
        let delay = UserDefaults.standard.string(forKey: "TracksPartyDelay").flatMap(Double.init) ?? 0.6
        try? await Task.sleep(for: .seconds(delay))
        let names = names(for: vibe)
        let offset = 2_000 + (PartyVibe.allCases.firstIndex(of: vibe) ?? 0) * 100
        let playlists = names.enumerated().compactMap { index, entry in
            playlist(id: "demo-party-\(vibe.rawValue)-\(index)", name: entry.name, curator: entry.curator, note: entry.note, songOffset: offset + index * 12)
        }
        let stations = [
            FeedItem(demoStation: String(localized: "\(vibe.title) Radio"), subtitle: String(localized: "Apple Music"), isLive: false),
            FeedItem(demoStation: String(localized: "Party Live"), subtitle: nil, isLive: true),
        ]
        return .found(PartyCatalog.Found(playlists: playlists, stations: stations))
    }

    private static func names(for vibe: PartyVibe) -> [(name: String, curator: String, note: String)] {
        let apple = "Apple Music"
        let top: (String, String) = switch vibe {
        case .danceFloor: ("Dance Floor Fillers", "Twelve years of songs that have never once emptied a room. Start here and the floor stays full till the lights come on.")
        case .houseParty: ("House Party Anthems", "Big, familiar songs for a full kitchen and a louder living room.")
        case .pregame: ("Pregame Heat", "Loud, bright and fast: the songs for getting ready and getting going.")
        case .dinnerParty: ("Dinner Party Jazz", "Warm, unhurried jazz and soul that sits just under the conversation.")
        case .backyard: ("Backyard BBQ", "Sunny grooves, cold drinks and a grill going. Summer's soundtrack, whatever the month.")
        case .throwback: ("Throwback Party", "The hits from three decades that everyone still knows every word to.")
        case .hipHop: ("Hip-Hop Party Starters", "The records that turn a room up, from the classics to this year's biggest.")
        case .latinNight: ("Fiesta Latina", "Reggaeton, salsa and bachata to keep everyone dancing till late.")
        case .allAges: ("Family Dance Party", "Clean, happy songs the whole family can sing along to.")
        }
        let rest: [(String, String)] = [
            ("Friday Night Party", apple), ("Party Starters", apple), ("Late Night Moves", apple),
            ("\(vibe.title) Essentials", apple), ("Crowd Pleasers", "Paper Lanterns"), ("Kitchen Disco", "Violet Radio"),
            ("All Night Long", apple), ("Sing-Along Hits", apple), ("Weekend Mode", "North Atlas"),
            ("Good Times Only", apple),
        ]
        return [(top.0, apple, top.1)] + rest.map { ($0.0, $0.1, "") }
    }

    private static func playlist(id: String, name: String, curator: String, note: String, songOffset: Int) -> Playlist? {
        let tracks = DemoCatalog.songs(count: 12, offset: songOffset, artists: nil).map { song in
            #"{"id":"\#(song.id.rawValue)","type":"songs","attributes":{"name":"\#(song.title)","artistName":"\#(song.artistName)","albumName":"\#(song.albumTitle ?? song.title)","durationInMillis":\#(Int((song.duration ?? 200) * 1000))}}"#
        }.joined(separator: ",")
        let description = note.isEmpty ? "" : #","description":{"standard":"\#(note)","short":"\#(note)"}"#
        let json = #"""
        {"id":"\#(id)","type":"playlists","attributes":{"name":"\#(name)","curatorName":"\#(curator)","playlistType":"\#(curator == "Apple Music" ? "editorial" : "external")"\#(description)},"relationships":{"tracks":{"data":[\#(tracks)]}}}
        """#
        return try? JSONDecoder().decode(Playlist.self, from: Data(json.utf8))
    }
}
#endif
