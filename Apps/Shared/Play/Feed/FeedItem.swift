import Foundation
import MusicKit
import TracksCore

/// A station, album or playlist on the Play page, whatever it came from.
struct FeedItem: Identifiable, Hashable {
    enum Content: Hashable {
        case station(MusicKit.Station)
        case album(Album)
        case playlist(Playlist)
        /// A made-up station, with sample data.
        case demoStation(String)
    }

    let content: Content
    let title: String
    let subtitle: String?
    let cover: CoverArt
    let isLive: Bool
    /// An explicit album. Stations and playlists aren't rated.
    var isExplicit = false
    /// An album's release year, so same-named albums aren't taken for versions of each other.
    var year: Int?

    var id: String {
        switch content {
        case .station(let station): "station.\(station.id.rawValue)"
        case .album(let album): "album.\(album.id.rawValue)"
        case .playlist(let playlist): "playlist.\(playlist.id.rawValue)"
        case .demoStation(let name): "demo.\(name)"
        }
    }

    /// Stations play when tapped; albums and playlists open.
    var playsWhenTapped: Bool {
        switch content {
        case .station, .demoStation: true
        case .album, .playlist: false
        }
    }

    var isStation: Bool { playsWhenTapped }

    init(station: MusicKit.Station, subtitle: String? = nil) {
        content = .station(station)
        title = station.name
        // An empty subtitle means none: a live station's badge already says it.
        let line = subtitle ?? station.stationProviderName
        self.subtitle = line?.isEmpty == true ? nil : line
        cover = station.artwork.map(CoverArt.artwork) ?? .url(nil, seed: station.name)
        isLive = station.isLive
    }

    init(album: Album) {
        content = .album(album)
        title = album.title
        subtitle = album.artistName
        cover = album.artwork.map(CoverArt.artwork) ?? .url(nil, seed: album.title)
        isLive = false
        isExplicit = album.contentRating == .explicit
        year = album.releaseDate.map { Calendar.current.component(.year, from: $0) }
    }

    init(playlist: Playlist) {
        content = .playlist(playlist)
        title = playlist.name
        subtitle = playlist.curatorName
        cover = playlist.artwork.map(CoverArt.artwork) ?? .url(nil, seed: playlist.name)
        isLive = false
    }

    init(demoStation name: String, subtitle: String?, isLive: Bool) {
        content = .demoStation(name)
        title = name
        self.subtitle = subtitle
        cover = .url(nil, seed: name)
        self.isLive = isLive
    }

    init?(recent item: RecentlyPlayedMusicItem) {
        switch item {
        case .album(let album): self.init(album: album)
        case .playlist(let playlist): self.init(playlist: playlist)
        case .station(let station): self.init(station: station)
        @unknown default: return nil
        }
    }

    init?(recommended item: MusicPersonalRecommendation.Item) {
        switch item {
        case .album(let album): self.init(album: album)
        case .playlist(let playlist): self.init(playlist: playlist)
        case .station(let station): self.init(station: station)
        @unknown default: return nil
        }
    }

    /// One version of each album under the explicit setting; stations and playlists as they are.
    static func versions(_ items: [FeedItem], allowsExplicit: Bool = PlayPreferences.allowsExplicit) -> [FeedItem] {
        ExplicitVersions.pick(
            items,
            allowsExplicit: allowsExplicit,
            // Only albums come in versions; anything else keys on its own id, so stays.
            title: { item in
                if case .album = item.content { return item.title }
                return item.id
            },
            artist: { $0.subtitle ?? "" },
            isExplicit: \.isExplicit,
            discriminator: { $0.year.map(String.init) ?? "" }
        )
    }

    /// What to hand the player for a station.
    var stationRequest: (PlayRequest, PlayContext)? {
        switch content {
        case .station(let station): (.station(station), PlayContext(kind: .station, title: station.name))
        case .demoStation(let name): (.demoStation(name, isLive: isLive), PlayContext(kind: .station, title: name))
        case .album, .playlist: nil
        }
    }
}
