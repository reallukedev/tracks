import Foundation

/// A made-up but believable listening history, for screenshots, previews and trying the app
/// without an Apple Music account. Every artist, album and song name here is invented.
///
/// Same seed and date in, same history out, so screenshots are reproducible.
public enum DemoLibrary {
    public struct Play: Sendable, Equatable {
        public let title: String
        public let artistName: String
        public let albumTitle: String
        public let kind: CaptureKind
        public let capturedAt: Date
        public let stationName: String?
        public let isScrobbled: Bool
        public let isPlayedBack: Bool
    }

    /// Every invented artist, so real data can be told apart from sample data.
    public static var artistNames: [String] { Catalog.artistNames }
    /// Every artist credit on an invented song: each artist, and the collaborations.
    public static var artistCredits: [String] {
        Catalog.artistNames + Catalog.collaborations.compactMap(\.credit)
    }
    public static var albumNames: [String] { Catalog.albumNames }

    public static let stations = [
        "Late Night Jazz Radio", "Indie Rising Station", "Chill Station", "Morning Mix Radio",
    ]

    /// About ten months of listening ending at `now`, with the last two weeks unbroken.
    public static func plays(
        endingAt now: Date = .now,
        calendar: Calendar = .current,
        days: Int = 300,
        seed: UInt64 = 2026
    ) -> [Play] {
        var random = SeededGenerator(seed: seed)
        let catalog = Catalog.make(using: &random)
        let today = calendar.startOfDay(for: now)
        var plays: [Play] = []

        for dayOffset in stride(from: days, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: today) else { continue }
            // The odd day off, but never in the last two weeks, so there's a streak to show
            // whatever time of day it is.
            let isRecent = dayOffset < 14
            if !isRecent, Double.random(in: 0...1, using: &random) < 0.09 { continue }

            // Listening grows a little over the year, which gives the trend charts a shape.
            let growth = 0.75 + 0.45 * (1 - Double(dayOffset) / Double(days))
            // Artists join the rotation over time, so there are discoveries every month.
            let unlocked = catalog.artists.filter { $0.debutOffset >= dayOffset }

            for window in listeningWindows(for: day, calendar: calendar, using: &random) {
                var cursor = window.start
                let mode = SessionMode.pick(using: &random)
                let station = mode == .radio ? stations.randomElement(using: &random) : nil
                var queue = songs(for: mode, from: unlocked, catalog: catalog, using: &random)
                let target = Int(Double(window.songs) * growth)
                var played = 0
                while played < target, cursor < window.end, cursor <= now, !queue.isEmpty {
                    let song = queue.removeFirst()
                    plays.append(Play(
                        title: song.title,
                        artistName: song.artist,
                        albumTitle: song.album,
                        kind: mode == .radio ? .radio : .onDemand,
                        capturedAt: cursor,
                        stationName: station,
                        isScrobbled: true,
                        isPlayedBack: mode == .radio && Double.random(in: 0...1, using: &random) < 0.3
                    ))
                    cursor = cursor.addingTimeInterval(song.length + Double.random(in: 2...14, using: &random))
                    played += 1
                    if queue.isEmpty { queue = songs(for: mode, from: unlocked, catalog: catalog, using: &random) }
                }
            }

            // Three plays of one song on a single recent day, for "on repeat".
            if dayOffset == 2, let favourite = catalog.artists.first?.albums.first?.songs[1],
               let evening = calendar.date(bySettingHour: 21, minute: 5, second: 0, of: day) {
                for index in 0..<3 {
                    plays.append(Play(
                        title: favourite.title, artistName: favourite.artist, albumTitle: favourite.album,
                        kind: .onDemand, capturedAt: evening.addingTimeInterval(Double(index) * 212),
                        stationName: nil, isScrobbled: true, isPlayedBack: false
                    ))
                }
            }
        }

        plays.sort { $0.capturedAt < $1.capturedAt }
        // A few songs recovered from Apple's history, a few read from Last.fm, and the latest
        // few not yet sent to Last.fm, so those states show up too.
        return plays.enumerated().map { index, play in
            var kind = play.kind
            if play.kind == .onDemand, index % 23 == 7 {
                kind = .imported
            } else if play.kind == .onDemand, index % 29 == 11 {
                kind = .lastFM
            }
            return Play(
                title: play.title,
                artistName: play.artistName,
                albumTitle: play.albumTitle,
                kind: kind,
                capturedAt: play.capturedAt,
                stationName: play.stationName,
                isScrobbled: index < plays.count - 3,
                isPlayedBack: play.isPlayedBack
            )
        }
    }

    /// A genre and release year for every invented song, by song identity, so sample data
    /// has genres and decades to show without asking Apple Music about made-up songs. Takes
    /// the same seed as ``plays(endingAt:calendar:days:seed:)`` and draws nothing extra from
    /// it, so the histories stay as they were.
    public static func songMetadata(seed: UInt64 = 2026) -> [String: SongMetadata] {
        var random = SeededGenerator(seed: seed)
        let catalog = Catalog.make(using: &random)
        var result: [String: SongMetadata] = [:]
        for (rank, artist) in catalog.artists.enumerated() {
            let genre = Catalog.genres[rank % Catalog.genres.count]
            for (number, album) in artist.albums.enumerated() {
                // Favourites have catalogues going back decades; the long tail is newer.
                let year = 2025 - (rank * 7 + number * 4) % (rank < 6 ? 40 : 15)
                for song in album.songs {
                    result[HistoryImport.key(title: song.title, artistName: song.artist)] =
                        SongMetadata(genre: genre, releaseYear: year, artists: Catalog.catalogArtists(of: song))
                }
            }
        }
        return result
    }

    /// One more sample song, played on demand at `date`. The Debug-only live feed uses it to
    /// show screens changing as listening arrives. `number` picks the song; favourites come
    /// up often, so charts reshuffle as well as grow.
    public static func livePlay(at date: Date, number: Int) -> Play {
        var random = SeededGenerator(seed: 2026)
        let catalog = Catalog.make(using: &random)
        let songs = catalog.artists.prefix(8).flatMap { $0.albums.prefix(1).flatMap(\.songs) }
        let song = songs[(number &* 7) % songs.count]
        return Play(
            title: song.title,
            artistName: song.artist,
            albumTitle: song.album,
            kind: .onDemand,
            capturedAt: date,
            stationName: nil,
            isScrobbled: false,
            isPlayedBack: false
        )
    }

    // MARK: - Shape of a day

    private struct Window {
        let start: Date
        let end: Date
        let songs: Int
    }

    private static func listeningWindows(
        for day: Date,
        calendar: Calendar,
        using random: inout SeededGenerator
    ) -> [Window] {
        func at(_ hour: Double, lasting hours: Double, songs: ClosedRange<Int>) -> Window? {
            let jitter = Double.random(in: -0.4...0.4, using: &random)
            guard let start = calendar.date(byAdding: .minute, value: Int((hour + jitter) * 60), to: day)
            else { return nil }
            return Window(
                start: start,
                end: start.addingTimeInterval(hours * 3600),
                songs: Int.random(in: songs, using: &random)
            )
        }

        var windows: [Window?] = []
        if calendar.isDateInWeekend(day) {
            windows.append(at(10.5, lasting: 2, songs: 6...14))
            if Bool.random(using: &random) { windows.append(at(15, lasting: 2, songs: 4...10)) }
            windows.append(at(20, lasting: 4, songs: 10...20))
        } else {
            windows.append(at(7.9, lasting: 1, songs: 5...10))
            if Double.random(in: 0...1, using: &random) < 0.4 { windows.append(at(12.4, lasting: 0.8, songs: 3...7)) }
            windows.append(at(18.5, lasting: 1.5, songs: 4...9))
            if Double.random(in: 0...1, using: &random) < 0.7 { windows.append(at(21.8, lasting: 2.5, songs: 6...14)) }
        }
        return windows.compactMap { $0 }
    }

    private enum SessionMode {
        case album, favourites, radio

        static func pick(using random: inout SeededGenerator) -> SessionMode {
            switch Double.random(in: 0...1, using: &random) {
            case ..<0.35: .album
            case ..<0.75: .favourites
            default: .radio
            }
        }
    }

    private static func songs(
        for mode: SessionMode,
        from artists: [Catalog.Artist],
        catalog: Catalog,
        using random: inout SeededGenerator
    ) -> [Catalog.Song] {
        let pool = artists.isEmpty ? Array(catalog.artists.prefix(3)) : artists
        switch mode {
        case .album:
            let artist = weightedArtist(from: pool, using: &random)
            return artist.albums.randomElement(using: &random)?.songs ?? []
        case .favourites:
            return (0..<12).compactMap { _ in
                let artist = weightedArtist(from: pool, using: &random)
                let album = artist.albums.randomElement(using: &random)
                // Earlier tracks on an album get played more.
                let songs = album?.songs ?? []
                guard !songs.isEmpty else { return nil }
                let index = min(songs.count - 1, Int(pow(Double.random(in: 0...1, using: &random), 1.8) * Double(songs.count)))
                return songs[index]
            }
        case .radio:
            return (0..<12).compactMap { _ in
                pool.randomElement(using: &random)?.albums.randomElement(using: &random)?.songs.randomElement(using: &random)
            }
        }
    }

    /// Roughly Zipf: a handful of favourites and a long tail.
    private static func weightedArtist(from artists: [Catalog.Artist], using random: inout SeededGenerator) -> Catalog.Artist {
        let total = artists.reduce(0) { $0 + $1.weight }
        var roll = Double.random(in: 0..<total, using: &random)
        for artist in artists {
            roll -= artist.weight
            if roll < 0 { return artist }
        }
        return artists[artists.count - 1]
    }
}

// MARK: - The invented catalogue

private struct Catalog {
    struct Song {
        let title: String
        let artist: String
        let album: String
        let length: TimeInterval
    }

    struct Album {
        let title: String
        let songs: [Song]
    }

    struct Artist {
        let name: String
        let albums: [Album]
        let weight: Double
        /// How many days ago they first appear.
        let debutOffset: Int
    }

    let artists: [Artist]

    /// Real Apple Music genre names, handed out by artist.
    static let genres = [
        "Indie Pop", "Alternative", "R&B/Soul", "Electronic", "Hip-Hop/Rap", "Singer/Songwriter",
        "Pop", "Jazz", "Dance", "Folk",
    ]

    static let artistNames = [
        "Mara Solis", "Juniper Lane", "Nova Harbor", "Wren & Ivy", "Hollow Pines", "The Velvet Hours",
        "Solstice Club", "Lumen Drive", "Amara Vale", "Northern Static", "Kaito Rivers", "Ada Kestrel",
        "Blue Arcade", "Paper Moons", "Sierra Hale", "Tidal Bloom", "Orchid Club", "Rowan Ellis",
        "Silver Coast", "Ivory Tapes", "Luca Marin", "Fern & Fable", "Neon Meridian", "Cassia Ray",
        "The Quiet Year", "Mika Sol", "Atlas Grove", "June Reverie", "Harbor Lights", "Elio Brandt",
        "Low Tide Society", "Margo Finch",
    ]

    static let albumNames = [
        "Tides", "Glasshouse", "Night Swimming Lessons", "Soft Focus", "Northbound", "Afterglow Radio",
        "Paper Houses", "Blue Hour", "Small Constellations", "Weathervane", "Island Time", "Static Bloom",
        "Monochrome Summer", "Holding Pattern", "The Long Weekend", "Salt & Honey", "Quiet Machines",
        "Open Water", "Satellite Hearts", "Ferris Wheel", "Wildflower Season", "Lanterns", "Undercurrent",
        "Parallel Lines", "Neon Garden", "Coastal Drive", "Late Bloomer", "Silver Linings Club",
        "Kaleidoscope Morning", "Echo Park Diaries", "Postcards", "Glow", "Faraway Friends", "Moth & Flame",
        "Daylight Savings", "Evergreen", "Low Light", "Porchlight", "Heatwave", "First Frost",
        "Golden Static", "Driftwood", "Midnight Bakery", "Paper Crowns", "Slow Dance Club", "Overpass",
        "Harbour Songs", "Night Market", "Almanac", "Second Nature", "Tall Grass", "Mirror Lake",
        "Cloud Club", "Seasonal", "Room Tone", "Weekend Weather", "Softly, Softly", "Longhand",
        "The Green Room", "Sunroom", "Distant Shores", "Field Recordings",
    ]

    static let songNames = [
        "Saltwater", "Undertow", "Paper Moon", "Glass Heart", "Night Drive", "Weightless", "Coastline",
        "Velvet Signal", "Late Summer", "Satellite", "Orange Sky", "Northern Lights", "Slow Motion",
        "Honey", "Neon Tide", "Afterimage", "Wildfire", "Porch Swing", "Moonlit", "Echoes", "Daydream",
        "Ferris Wheel", "Lighthouse", "Parallel", "Constellations", "Borrowed Time", "Still Water",
        "Heatwave", "Denim Weather", "Kaleidoscope", "Firefly", "Open Road", "Marigold", "Quiet Hours",
        "Silver Lining", "Paper Boats", "Overpass", "Weathervane", "Fever Dream", "Wanderer",
        "Evergreen", "Cinnamon", "Dandelion", "Postcard", "Low Light", "Sunday Morning Radio", "Tangerine",
        "Soft Spot", "Starling", "Rewind", "Horizon Line", "Headlights", "Gravity", "Polaroid", "Undone",
        "Ghost Town Glow", "Lemonade Sky", "Driftwood", "Midnight Bakery", "Aurora", "Night Train Home",
        "Golden", "Hummingbird", "Seaglass", "Rooftops", "Lanterns", "Butterflies", "Moth", "Ivy",
        "Wavelength", "Static", "Afterparty", "Wild Run", "Wintergreen", "Blueprint", "Echo Park",
        "Faraway", "Sparrow", "Carousel", "Riverbed", "Nightshade", "Brighter", "Fool's Gold", "Lullaby",
        "Paper Crown", "Rosewater", "Skyline", "Tidal", "Glow", "Swim", "Wool & Weather",
        "Cherry Cola", "Hometown", "Shoreline", "Violet", "Disco Moon", "Summer Rain", "Hurricane",
        "Neon Lights", "Almost Home", "Stargazer", "Backseat", "Satellite Hearts", "Crystal Clear",
        "Wildflowers", "Cold Coffee", "Late Checkout", "Glass Town", "Dreamland", "Blue Hour",
        "Moonrise", "Deep End", "Radio Silence", "Pine", "Wander", "Afterglow", "Open Ocean",
        "Rain Check", "Say It Twice", "Second Guess", "Slow Burn", "Ten Past Two", "Take the Long Way",
        "Tell Me Softly", "The Quiet Part", "Too Late to Call", "Waiting Room", "Worn Out Shoes",
    ]

    static func make(using random: inout SeededGenerator) -> Catalog {
        var albumPool = albumNames.shuffled(using: &random)
        var songPool = songNames.shuffled(using: &random)
        var artists: [Artist] = []

        for (rank, name) in artistNames.enumerated() {
            let albumCount = rank < 8 ? 3 : (rank < 20 ? 2 : 1)
            var albums: [Album] = []
            for _ in 0..<albumCount {
                // 60 album slots and 62 names, so no two artists share an album title.
                let title = albumPool.isEmpty ? "Untitled \(albums.count + 1)" : albumPool.removeFirst()
                let songs = (0..<Int.random(in: 4...7, using: &random)).map { _ in
                    if songPool.isEmpty { songPool = songNames.shuffled(using: &random) }
                    return Song(
                        title: songPool.removeFirst(),
                        artist: name,
                        album: title,
                        length: Double.random(in: 150...290, using: &random)
                    )
                }
                albums.append(Album(title: title, songs: songs))
            }
            // Favourites have always been around; the long tail arrives over the year.
            let debut = rank < 10 ? 400 : Int.random(in: 5...280, using: &random)
            artists.append(Artist(
                name: name,
                albums: albums,
                weight: 1 / pow(Double(rank + 1), 0.95),
                debutOffset: debut
            ))
        }
        // After every draw, so the history around them stays as it was.
        for collaboration in collaborations {
            let song = artists[collaboration.artist].albums[collaboration.album].songs[collaboration.song]
            let albums = artists[collaboration.artist].albums
            var songs = albums[collaboration.album].songs
            songs[collaboration.song] = Song(
                title: song.title + (collaboration.titleFeature.map { " (feat. \($0))" } ?? ""),
                artist: collaboration.credit ?? song.artist,
                album: song.album,
                length: song.length
            )
            var updated = albums
            updated[collaboration.album] = Album(title: albums[collaboration.album].title, songs: songs)
            let artist = artists[collaboration.artist]
            artists[collaboration.artist] = Artist(name: artist.name, albums: updated, weight: artist.weight, debutOffset: artist.debutOffset)
        }
        return Catalog(artists: artists)
    }

    struct Collaboration {
        /// Where the song is: artist, album and song, by position.
        let artist: Int
        let album: Int
        let song: Int
        /// The song's whole artist credit, when it isn't the artist alone.
        var credit: String?
        /// Someone featured in the title, as Apple Music writes it.
        var titleFeature: String?
        /// Who Apple Music would list as the song's artists.
        let catalog: [String]
    }

    /// Songs by more than one artist, one of each kind of credit.
    static let collaborations = [
        Collaboration(artist: 0, album: 1, song: 2, credit: "Mara Solis & Nova Harbor", catalog: ["Mara Solis", "Nova Harbor"]),
        Collaboration(artist: 1, album: 0, song: 3, titleFeature: "Kaito Rivers", catalog: ["Juniper Lane", "Kaito Rivers"]),
        Collaboration(artist: 2, album: 1, song: 0, credit: "Nova Harbor feat. Ada Kestrel", catalog: ["Nova Harbor", "Ada Kestrel"]),
        Collaboration(artist: 3, album: 0, song: 2, credit: "Wren & Ivy feat. Mara Solis", catalog: ["Wren & Ivy", "Mara Solis"]),
        Collaboration(
            artist: 4, album: 0, song: 2,
            credit: "Hollow Pines, Amara Vale, Luca Marin & Cassia Ray",
            catalog: ["Hollow Pines", "Amara Vale", "Luca Marin", "Cassia Ray"]
        ),
        Collaboration(artist: 5, album: 0, song: 1, credit: "The Velvet Hours x Mara Solis", catalog: ["The Velvet Hours", "Mara Solis"]),
        Collaboration(
            artist: 6, album: 0, song: 2,
            titleFeature: "Anastasia Montgomery-Whitfield",
            catalog: ["Solstice Club", "Anastasia Montgomery-Whitfield"]
        ),
    ]

    /// The catalog's artists for a song, by its artist credit and title.
    static func catalogArtists(of song: Song) -> [String] {
        collaborations.first { $0.credit == song.artist || ($0.titleFeature.map { song.title.hasSuffix("(feat. \($0))") } ?? false) }?
            .catalog ?? [song.artist]
    }
}

/// SplitMix64. Small, fast and good enough for invented listening.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
