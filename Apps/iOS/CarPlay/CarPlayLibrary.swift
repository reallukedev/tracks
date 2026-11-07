import UIKit
import CarPlay
import MusicKit
import TracksCore

/// Library: where your music is kept, a place at a time, as Music's Library is in the car.
/// Playlists, Artists, Albums, Songs and Downloaded open their lists, and what you added lately
/// sits under them as covers. An album, playlist or artist opens as a page with Play and
/// Shuffle at the top and its songs below, rather than playing at a touch.
extension CarPlaySceneDelegate {
    // MARK: - Apple Music

    func appleMusicLibrarySections() async -> [CPListSection] {
        guard MusicAuthorization.currentStatus == .authorized, !model.isDemoLaunch else {
            library.emptyViewTitleVariants = [String(localized: "Library Unavailable")]
            library.emptyViewSubtitleVariants = [String(localized: "Allow Apple Music access in Tracks on your iPhone to see your library here.")]
            return []
        }
        let places = CPListSection(items: [
            place(String(localized: "Playlists"), symbol: "music.note.list") { [weak self] in await self?.appleMusicPlaylistsPage() },
            place(String(localized: "Artists"), symbol: "music.microphone") { [weak self] in await self?.appleMusicArtistsPage() },
            place(String(localized: "Albums"), symbol: "square.stack") { [weak self] in await self?.appleMusicAlbumsPage() },
            place(String(localized: "Songs"), symbol: "music.note") { [weak self] in await self?.appleMusicSongsPage() },
            place(String(localized: "Downloaded"), symbol: "arrow.down.circle") { [weak self] in await self?.appleMusicDownloadedPage() },
        ])
        var sections = [places]

        var request = MusicLibraryRequest<Album>()
        request.sort(by: \.libraryAddedDate, ascending: false)
        request.limit = 12
        if let albums = try? await request.response().items, !albums.isEmpty {
            let items = Array(FeedItem.versions(albums.map(FeedItem.init(album:))).prefix(Int(CPMaximumNumberOfGridImages)))
            let (side, scale) = (CPListImageRowItemImageGridElement.maximumImageSize.height, scale)
            let late = CarPlayImages.Late()
            let images = await CarPlayImages.batch(items.count, standIn: { index in
                CarPlayImages.generated(seed: items[index].title, side: side, scale: scale)
            }, late: { index, image in
                late.set(index, image)
            }) { index in
                await CarPlayImages.cover(for: items[index], side: side, scale: scale)
            }
            let tiles = zip(items, images).map { item, image in
                CPListImageRowItemImageGridElement(image: image, imageShape: .roundedRectangle, title: item.title, accessorySymbolName: nil)
            }
            late.attach(tiles)
            let row = CPListImageRowItem(text: String(localized: "Recently Added"), imageGridElements: tiles, allowsMultipleLines: false)
            row.listImageRowHandler = { [weak self] _, index, completion in
                guard items.indices.contains(index), case .album(let album) = items[index].content else { return completion() }
                self?.open({ await self?.appleMusicAlbumPage(album) }, then: completion)
            }
            sections.append(CPListSection(items: [row]))
        }
        return sections
    }

    private func appleMusicPlaylistsPage() async -> CPListTemplate {
        var request = MusicLibraryRequest<Playlist>()
        request.sort(by: \.lastPlayedDate, ascending: false)
        request.limit = CPListTemplate.maximumItemCount
        let playlists = (try? await request.response().items).map(Array.init) ?? []
        let rows = playlistRows(playlists)
        return page(String(localized: "Playlists"), [CPListSection(items: rows)], empty: String(localized: "No Playlists"))
    }

    /// Playlists as rows, their covers filling in once the page is open.
    func playlistRows(_ playlists: [Playlist]) -> [CPListItem] {
        let side = CPListItem.maximumImageSize.height
        let standIn = CarPlayImages.placeholder(symbol: "music.note.list", side: side, scale: scale)
        var rows: [CPListItem] = []
        for playlist in playlists {
            let item = FeedItem(playlist: playlist)
            let row = CPListItem(text: playlist.name, detailText: item.subtitle, image: standIn, accessoryImage: nil, accessoryType: .disclosureIndicator)
            row.isPlaying = isPlaying(playlist.name)
            row.handler = { [weak self] _, completion in
                self?.open({ await self?.appleMusicPlaylistPage(playlist) }, then: completion)
            }
            rows.append(row)
        }
        let scale = scale
        fillImages(rows) { index in
            await CarPlayImages.cover(for: FeedItem(playlist: playlists[index]), side: side, scale: scale)
        }
        return rows
    }

    private func appleMusicAlbumsPage() async -> CPListTemplate {
        var request = MusicLibraryRequest<Album>()
        request.sort(by: \.libraryAddedDate, ascending: false)
        request.limit = CPListTemplate.maximumItemCount
        let albums = (try? await request.response().items).map(Array.init) ?? []
        return page(String(localized: "Albums"), [CPListSection(items: albumRows(albums))], empty: String(localized: "No Albums"))
    }

    /// Albums as rows, their covers filling in once the page is open.
    func albumRows(_ albums: [Album], detail: (Album) -> String? = { $0.artistName }) -> [CPListItem] {
        let side = CPListItem.maximumImageSize.height
        let standIn = CarPlayImages.placeholder(symbol: "square.stack", side: side, scale: scale)
        var rows: [CPListItem] = []
        for album in albums {
            let row = CPListItem(text: album.title, detailText: detail(album), image: standIn, accessoryImage: nil, accessoryType: .disclosureIndicator)
            row.isExplicitContent = album.contentRating == .explicit
            row.isPlaying = isPlaying(album.title)
            row.handler = { [weak self] _, completion in
                self?.open({ await self?.appleMusicAlbumPage(album) }, then: completion)
            }
            rows.append(row)
        }
        let scale = scale
        fillImages(rows) { index in
            await CarPlayImages.cover(for: FeedItem(album: albums[index]), side: side, scale: scale)
        }
        return rows
    }

    /// Artists by name, each in a circle as Music draws them: the picture Apple Music has,
    /// filled in once the page is open, and a quiet stand-in until then.
    private func appleMusicArtistsPage() async -> CPListTemplate {
        var request = MusicLibraryRequest<Artist>()
        request.sort(by: \.name, ascending: true)
        request.limit = CPListTemplate.maximumItemCount
        let artists = (try? await request.response().items).map(Array.init) ?? []
        let side = CPListItem.maximumImageSize.height
        let standIn = CarPlayImages.placeholder(symbol: "music.microphone", side: side, scale: scale, round: true)
        let rows = artists.map { artist in
            let row = CPListItem(text: artist.name, detailText: nil, image: standIn, accessoryImage: nil, accessoryType: .disclosureIndicator)
            row.isPlaying = isPlaying(artist.name)
            row.handler = { [weak self] _, completion in
                self?.open({ await self?.appleMusicArtistPage(artist) }, then: completion)
            }
            return row
        }
        let (scale, feed) = (scale, model.playFeed)
        fillImages(rows) { index in
            await CarPlayImages.artistPicture(named: artists[index].name, side: side, scale: scale, feed: feed)
        }
        return page(String(localized: "Artists"), [CPListSection(items: rows)], empty: String(localized: "No Artists"))
    }

    /// An artist in your library: Play and Shuffle their songs, then their albums, newest first.
    private func appleMusicArtistPage(_ artist: Artist) async -> CPListTemplate {
        let player = model.player
        var albumRequest = MusicLibraryRequest<Album>()
        albumRequest.filter(matching: \.artists, contains: artist)
        albumRequest.sort(by: \.releaseDate, ascending: false)
        let albums = (try? await albumRequest.response().items).map(Array.init) ?? []
        var songRequest = MusicLibraryRequest<Song>()
        songRequest.filter(matching: \.artists, contains: artist)
        let songs = (try? await songRequest.response().items).map(Array.init) ?? []

        let context = PlayContext(kind: .artist, title: artist.name)
        let actions = playRows(
            detail: Self.count(albums: albums.count, songs: songs.count),
            play: songs.isEmpty ? nil : { await player.start(.songs(songs), from: context) },
            shuffle: songs.isEmpty ? nil : { await player.start(.songs(songs), from: context, shuffled: true) }
        )
        let rows = albumRows(Array(albums.prefix(Self.pageRowLimit))) { album in album.releaseDate.map { String(Calendar.current.component(.year, from: $0)) } }
        return CPListTemplate(title: artist.name, sections: Self.section(actions) + (rows.isEmpty ? [] : [CPListSection(items: rows, header: String(localized: "Albums"), sectionIndexTitle: nil)]), assistantCellConfiguration: nil)
    }

    /// Every song, A to Z, under a row that shuffles the lot: in the car, Songs is mostly
    /// for Shuffle.
    private func appleMusicSongsPage() async -> CPListTemplate {
        let player = model.player
        var request = MusicLibraryRequest<Song>()
        request.sort(by: \.title, ascending: true)
        request.limit = max(1, CPListTemplate.maximumItemCount - 1)
        let songs = (try? await request.response().items).map(Array.init) ?? []
        guard !songs.isEmpty else {
            return page(String(localized: "Songs"), [], empty: String(localized: "No Songs"))
        }
        let shuffle = shuffleAllRow {
            // From the whole library, not just the page: a few hundred, picked at random.
            var all = MusicLibraryRequest<Song>()
            all.limit = 5000
            let every = (try? await all.response().items).map(Array.init) ?? songs
            let picked = Array(every.shuffled().prefix(300))
            await player.start(.songs(picked), from: .songs(String(localized: "Songs")))
        }
        let context = PlayContext.songs(String(localized: "Songs"))
        let side = CPListItem.maximumImageSize.height
        let standIn = CarPlayImages.placeholder(symbol: "music.note", side: side, scale: scale)
        let rows = songs.enumerated().map { index, song in
            let row = CPListItem(text: song.title, detailText: song.artistName, image: standIn)
            row.isExplicitContent = song.contentRating == .explicit
            row.isPlaying = player.current?.song?.id == song.id
            row.handler = { [weak self] _, completion in
                self?.play({ await player.start(.songs(songs, startingAt: index), from: context) }, completion: completion)
            }
            return row
        }
        let scale = scale
        fillImages(rows) { index in
            let song = songs[index]
            let art = song.artwork.map(CoverArt.artwork) ?? .url(nil, seed: song.albumTitle ?? song.title)
            return await CarPlayImages.cover(art, side: side, scale: scale, album: song.albumTitle.map { ($0, song.artistName) })
        }
        return page(String(localized: "Songs"), [CPListSection(items: [shuffle] + rows)], empty: String(localized: "No Songs"))
    }

    /// What's on the iPhone, to play with no signal: downloaded playlists, then albums.
    private func appleMusicDownloadedPage() async -> CPListTemplate {
        var playlistRequest = MusicLibraryRequest<Playlist>()
        playlistRequest.includeOnlyDownloadedContent = true
        playlistRequest.sort(by: \.lastPlayedDate, ascending: false)
        playlistRequest.limit = 25
        let playlists = (try? await playlistRequest.response().items).map(Array.init) ?? []
        var albumRequest = MusicLibraryRequest<Album>()
        albumRequest.includeOnlyDownloadedContent = true
        albumRequest.sort(by: \.libraryAddedDate, ascending: false)
        albumRequest.limit = max(1, CPListTemplate.maximumItemCount - playlists.count)
        let albums = (try? await albumRequest.response().items).map(Array.init) ?? []

        var sections: [CPListSection] = []
        if !playlists.isEmpty {
            sections.append(CPListSection(items: playlistRows(playlists), header: String(localized: "Playlists"), sectionIndexTitle: nil))
        }
        if !albums.isEmpty {
            sections.append(CPListSection(items: albumRows(albums), header: String(localized: "Albums"), sectionIndexTitle: nil))
        }
        let downloaded = page(String(localized: "Downloaded"), sections, empty: String(localized: "Nothing Downloaded"))
        downloaded.emptyViewSubtitleVariants = [String(localized: "Download music in the Music app to play it here without a connection.")]
        return downloaded
    }

    func appleMusicAlbumPage(_ album: Album) async -> CPListTemplate {
        let player = model.player
        let detailed = (try? await album.with([.tracks])) ?? album
        let songs: [Song] = (detailed.tracks ?? []).compactMap { track in
            if case .song(let song) = track { return song }
            return nil
        }
        let context = PlayContext(kind: .album, title: album.title)
        let year = album.releaseDate.map { String(Calendar.current.component(.year, from: $0)) }
        let actions = playRows(
            detail: [album.artistName, year].compactMap { $0 }.joined(separator: " · "),
            play: { await player.start(.album(album), from: context) },
            shuffle: { await player.start(.album(album), from: context, shuffled: true) }
        )
        let rows = songs.prefix(Self.pageRowLimit).enumerated().map { index, song in
            let row = CPListItem(text: song.title, detailText: song.artistName == album.artistName ? Self.length(song.duration) : song.artistName)
            row.isExplicitContent = song.contentRating == .explicit
            row.isPlaying = player.current?.song?.id == song.id
            row.handler = { [weak self] _, completion in
                self?.play({ await player.start(.songs(songs, startingAt: index), from: context) }, completion: completion)
            }
            return row
        }
        return CPListTemplate(title: album.title, sections: [CPListSection(items: actions + rows)], assistantCellConfiguration: nil)
    }

    func appleMusicPlaylistPage(_ playlist: Playlist) async -> CPListTemplate {
        let player = model.player
        let detailed = (try? await playlist.with([.tracks])) ?? playlist
        let songs: [Song] = (detailed.tracks ?? []).compactMap { track in
            if case .song(let song) = track { return song }
            return nil
        }
        let context = PlayContext(kind: .playlist, title: playlist.name)
        let count = String(AttributedString(localized: "^[\(songs.count) song](inflect: true)").characters)
        let actions = playRows(
            detail: count,
            play: { await player.start(.playlist(playlist), from: context) },
            shuffle: { await player.start(.playlist(playlist), from: context, shuffled: true) }
        )
        var rows: [CPListItem] = []
        let listed = Array(songs.prefix(Self.pageRowLimit))
        let side = CPListItem.maximumImageSize.height
        let standIn = CarPlayImages.placeholder(symbol: "music.note", side: side, scale: scale)
        for (index, song) in listed.enumerated() {
            let row = CPListItem(text: song.title, detailText: song.artistName, image: standIn)
            row.isExplicitContent = song.contentRating == .explicit
            row.isPlaying = player.current?.song?.id == song.id
            row.handler = { [weak self] _, completion in
                self?.play({ await player.start(.songs(songs, startingAt: index), from: context) }, completion: completion)
            }
            rows.append(row)
        }
        let scale = scale
        fillImages(rows) { index in
            let song = listed[index]
            let art = song.artwork.map(CoverArt.artwork) ?? .url(nil, seed: song.albumTitle ?? song.title)
            return await CarPlayImages.cover(art, side: side, scale: scale, album: song.albumTitle.map { ($0, song.artistName) })
        }
        let page = CPListTemplate(title: playlist.name, sections: [CPListSection(items: actions + rows)], assistantCellConfiguration: nil)
        page.emptyViewTitleVariants = [String(localized: "No Songs to Play")]
        return page
    }

    // MARK: - Your music

    func yourMusicLibrarySections() async -> [CPListSection] {
        let music = model.yourMusic
        guard !music.index.isEmpty else {
            library.emptyViewTitleVariants = [String(localized: "No Music Yet")]
            library.emptyViewSubtitleVariants = [String(localized: "Songs you add to Tracks, and your servers' songs, show up here.")]
            return []
        }
        var places: [CPListItem] = []
        if !music.playlists.all.isEmpty {
            places.append(place(String(localized: "Playlists"), symbol: "music.note.list") { [weak self] in await self?.localPlaylistsPage() })
        }
        places.append(place(String(localized: "Artists"), symbol: "music.microphone") { [weak self] in await self?.localArtistsPage() })
        places.append(place(String(localized: "Albums"), symbol: "square.stack") { [weak self] in await self?.localAlbumsPage(music.index.albums, title: String(localized: "Albums")) })
        places.append(place(String(localized: "Songs"), symbol: "music.note") { [weak self] in await self?.localSongsPage(music.index.tracks, title: String(localized: "Songs")) })
        // Only with a server to download from: otherwise every song is already on the iPhone.
        if !music.downloads.items.isEmpty {
            places.append(place(String(localized: "Downloaded"), symbol: "arrow.down.circle") { [weak self] in
                await self?.localSongsPage(music.downloads.tracks.map(music.current), title: String(localized: "Downloaded"))
            })
        }
        var sections = [CPListSection(items: places)]

        let recent = Array(music.index.recentlyAdded.prefix(Int(CPMaximumNumberOfGridImages)))
        if !recent.isEmpty {
            let (side, scale) = (CPListImageRowItemImageGridElement.maximumImageSize.height, scale)
            let late = CarPlayImages.Late()
            let images = await CarPlayImages.batch(recent.count, standIn: { index in
                CarPlayImages.generated(seed: recent[index].title, side: side, scale: scale)
            }, late: { index, image in
                late.set(index, image)
            }) { [weak self] index in
                await self?.localCover(recent[index], side: side) ?? CarPlayImages.generated(seed: recent[index].title, side: side, scale: scale)
            }
            let tiles = zip(recent, images).map { album, image in
                CPListImageRowItemImageGridElement(image: image, imageShape: .roundedRectangle, title: album.displayTitle, accessorySymbolName: nil)
            }
            late.attach(tiles)
            let row = CPListImageRowItem(text: String(localized: "Recently Added"), imageGridElements: tiles, allowsMultipleLines: false)
            row.listImageRowHandler = { [weak self] _, index, completion in
                guard recent.indices.contains(index) else { return completion() }
                self?.open({ await self?.localAlbumPage(recent[index]) }, then: completion)
            }
            sections.append(CPListSection(items: [row]))
        }
        return sections
    }

    private func localPlaylistsPage() async -> CPListTemplate {
        let music = model.yourMusic
        let facts = model.playFeed.facts
        var rows: [CPListItem] = []
        var firsts: [LocalTrack?] = []
        let side = CPListItem.maximumImageSize.height
        let standIn = CarPlayImages.placeholder(symbol: "music.note.list", side: side, scale: scale)
        let playlists = Array(music.playlists.recent.prefix(Self.pageRowLimit))
        for playlist in playlists {
            let songs = music.songs(in: playlist, facts: facts)
            firsts.append(songs.first { $0.artwork != nil } ?? songs.first)
            let count = String(AttributedString(localized: "^[\(songs.count) song](inflect: true)").characters)
            let row = CPListItem(text: playlist.name, detailText: count, image: standIn, accessoryImage: nil, accessoryType: .disclosureIndicator)
            row.isPlaying = isPlaying(playlist.name)
            row.handler = { [weak self] _, completion in
                self?.open({ await self?.localPlaylistPage(playlist) }, then: completion)
            }
            rows.append(row)
        }
        let scale = scale
        fillImages(rows) { index in
            let first = firsts[index]
            return await CarPlayImages.cover(url: music.artworkURL(first?.artwork)?.absoluteString, seed: first?.album ?? playlists[index].name, side: side, scale: scale)
        }
        return page(String(localized: "Playlists"), [CPListSection(items: rows)], empty: String(localized: "No Playlists"))
    }

    private func localPlaylistPage(_ playlist: TracksPlaylist) async -> CPListTemplate {
        let music = model.yourMusic
        let player = model.player
        let songs = music.songs(in: playlist, facts: model.playFeed.facts)
        let playable = songs.filter(music.isPlayable)
        let context = PlayContext(kind: .playlist, title: playlist.name)
        let actions = playRows(
            detail: String(AttributedString(localized: "^[\(songs.count) song](inflect: true)").characters),
            play: playable.isEmpty ? nil : { await player.start(.local(playable), from: context) },
            shuffle: playable.isEmpty ? nil : { await player.start(.local(playable), from: context, shuffled: true) }
        )
        let rows = localSongRows(playable, context: context)
        let template = CPListTemplate(title: playlist.name, sections: [CPListSection(items: actions + rows)], assistantCellConfiguration: nil)
        template.emptyViewTitleVariants = [String(localized: "No Songs to Play")]
        return template
    }

    private func localAlbumsPage(_ albums: [LocalAlbum], title: String) async -> CPListTemplate {
        let listed = Array(albums.prefix(Self.pageRowLimit))
        let rows = localAlbumRows(listed) { $0.artist }
        return page(title, [CPListSection(items: rows)], empty: String(localized: "No Albums"))
    }

    /// Your albums as rows, their covers filling in once the page is open.
    private func localAlbumRows(_ albums: [LocalAlbum], detail: (LocalAlbum) -> String?) -> [CPListItem] {
        let side = CPListItem.maximumImageSize.height
        let standIn = CarPlayImages.placeholder(symbol: "square.stack", side: side, scale: scale)
        var rows: [CPListItem] = []
        for album in albums {
            let row = CPListItem(text: album.displayTitle, detailText: detail(album), image: standIn, accessoryImage: nil, accessoryType: .disclosureIndicator)
            row.isPlaying = isPlaying(album.title)
            row.handler = { [weak self] _, completion in
                self?.open({ await self?.localAlbumPage(album) }, then: completion)
            }
            rows.append(row)
        }
        fillImages(rows) { [weak self] index in
            await self?.localCover(albums[index], side: side)
        }
        return rows
    }

    private func localArtistsPage() async -> CPListTemplate {
        let music = model.yourMusic
        let artists = Array(music.index.artists.prefix(Self.pageRowLimit))
        let side = CPListItem.maximumImageSize.height
        let standIn = CarPlayImages.placeholder(symbol: "music.microphone", side: side, scale: scale, round: true)
        let rows = artists.map { artist in
            let albums = String(AttributedString(localized: "^[\(artist.albums.count) album](inflect: true)").characters)
            let row = CPListItem(text: artist.name, detailText: albums, image: standIn, accessoryImage: nil, accessoryType: .disclosureIndicator)
            row.isPlaying = isPlaying(artist.name)
            row.handler = { [weak self] _, completion in
                self?.open({ await self?.localArtistPage(artist) }, then: completion)
            }
            return row
        }
        // Their server's picture, or one of their covers, round.
        let scale = scale
        fillImages(rows) { index in
            guard let picture = music.artistPicture(for: artists[index]) else { return nil }
            return CarPlayImages.circle(await CarPlayImages.cover(picture, side: side, scale: scale))
        }
        return page(String(localized: "Artists"), [CPListSection(items: rows)], empty: String(localized: "No Artists"))
    }

    /// Songs A to Z under a row that shuffles them all.
    private func localSongsPage(_ tracks: [LocalTrack], title: String) async -> CPListTemplate {
        let music = model.yourMusic
        let player = model.player
        let playable = tracks.filter(music.isPlayable)
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        guard !playable.isEmpty else {
            return page(title, [], empty: String(localized: "No Songs to Play"))
        }
        let context = PlayContext.songs(title)
        let shuffle = shuffleAllRow {
            await player.start(.local(Array(playable.shuffled().prefix(500))), from: context)
        }
        let listed = Array(playable.prefix(max(1, CPListTemplate.maximumItemCount - 1)))
        let rows = localSongRows(listed, context: context)
        return page(title, [CPListSection(items: [shuffle] + rows)], empty: String(localized: "No Songs"))
    }

    /// Songs with their covers, which fill in once the page is open.
    private func localSongRows(_ tracks: [LocalTrack], context: PlayContext) -> [CPListItem] {
        let player = model.player
        let music = model.yourMusic
        let side = CPListItem.maximumImageSize.height
        let standIn = CarPlayImages.placeholder(symbol: "music.note", side: side, scale: scale)
        var rows: [CPListItem] = []
        let listed = Array(tracks.prefix(Self.pageRowLimit))
        for (index, track) in listed.enumerated() {
            let row = CPListItem(text: track.title, detailText: track.artist, image: standIn)
            row.isPlaying = player.current?.local?.id == track.id
            row.handler = { [weak self] _, completion in
                self?.play({ await player.start(.local(tracks, startingAt: index), from: context) }, completion: completion)
            }
            rows.append(row)
        }
        let scale = scale
        fillImages(rows) { index in
            let track = listed[index]
            return await CarPlayImages.cover(url: music.artworkURL(track.artwork)?.absoluteString, seed: track.album ?? track.title, side: side, scale: scale)
        }
        return rows
    }

    /// An artist's page: Play and Shuffle at the top, then their albums.
    func localArtistPage(_ artist: LocalArtist) async -> CPListTemplate {
        let music = model.yourMusic
        let player = model.player
        let tracks = artist.tracks.filter(music.isPlayable)
        let context = PlayContext(kind: .artist, title: artist.name)
        let actions = playRows(
            detail: Self.count(albums: artist.albums.count, songs: tracks.count),
            play: tracks.isEmpty ? nil : { await player.start(.local(tracks), from: context) },
            shuffle: tracks.isEmpty ? nil : { await player.start(.local(tracks), from: context, shuffled: true) }
        )
        let rows = localAlbumRows(Array(artist.albums.prefix(Self.pageRowLimit))) { $0.year.map(String.init) }
        return CPListTemplate(title: artist.name, sections: Self.section(actions) + (rows.isEmpty ? [] : [CPListSection(items: rows, header: String(localized: "Albums"), sectionIndexTitle: nil)]), assistantCellConfiguration: nil)
    }

    func localAlbumPage(_ album: LocalAlbum) async -> CPListTemplate {
        let music = model.yourMusic
        let player = model.player
        let tracks = album.tracks.filter(music.isPlayable)
        let context = PlayContext(kind: .album, title: album.title)
        let actions = playRows(
            detail: [album.artist, album.year.map(String.init)].compactMap { $0 }.joined(separator: " · "),
            play: tracks.isEmpty ? nil : { await player.start(.local(tracks), from: context) },
            shuffle: tracks.isEmpty ? nil : { await player.start(.local(tracks), from: context, shuffled: true) }
        )
        let rows = tracks.prefix(Self.pageRowLimit).enumerated().map { index, track in
            let row = CPListItem(text: track.title, detailText: track.artist == album.artist ? Self.length(track.duration) : track.artist)
            row.isPlaying = player.current?.local?.id == track.id
            row.handler = { [weak self] _, completion in
                self?.play({ await player.start(.local(tracks, startingAt: index), from: context) }, completion: completion)
            }
            return row
        }
        let template = CPListTemplate(title: album.displayTitle, sections: [CPListSection(items: actions + rows)], assistantCellConfiguration: nil)
        template.emptyViewTitleVariants = [String(localized: "No Songs to Play")]
        return template
    }

    private func localCover(_ album: LocalAlbum, side: CGFloat) async -> UIImage {
        await CarPlayImages.cover(url: model.yourMusic.artworkURL(album.artwork)?.absoluteString, seed: album.title, side: side, scale: scale)
    }

    // MARK: - Building blocks

    /// A row that opens a place in the library: its symbol, its name, and a chevron.
    private func place(_ title: String, symbol: String, open make: @escaping () async -> CPListTemplate?) -> CPListItem {
        let image = CarPlayImages.symbol(symbol, side: CPListItem.maximumImageSize.height, scale: scale)
        let row = CPListItem(text: title, detailText: nil, image: image, accessoryImage: nil, accessoryType: .disclosureIndicator)
        row.handler = { [weak self] _, completion in
            self?.open(make, then: completion)
        }
        return row
    }

    /// Pictures for a long list, drawn once it's open, from the top, a few at a time, so the
    /// page opens at once and fills in as you look at it. Rows keep their stand-in where
    /// there's no picture.
    ///
    /// Stops once the page has gone (popped, another tab, or the car disconnected), or if it
    /// never shows up.
    func fillImages(_ rows: [CPListItem], _ load: @escaping @MainActor (Int) async -> UIImage?) {
        guard let first = rows.first else { return }
        let started = Date.now
        Task { [weak self] in
            var wasShown = false
            for start in stride(from: 0, to: rows.count, by: 6) {
                guard let self else { return }
                if isShown(first) {
                    wasShown = true
                } else if wasShown || Date.now.timeIntervalSince(started) > 15 {
                    return
                }
                // Six side by side: each waits on its picture, not on the others. One that's
                // slow arrives on its own, without holding up the rest.
                let count = min(6, rows.count - start)
                let found = await CarPlayImages.gather(count, wait: .seconds(4), late: { index, image in
                    rows[start + index].setImage(image)
                }) { index in
                    await load(start + index)
                }
                for (index, image) in found {
                    rows[start + index].setImage(image)
                }
            }
        }
    }

    /// Whether a row is on a page that's open in the car.
    private func isShown(_ row: CPListItem) -> Bool {
        interface?.templates.contains { template in
            (template as? CPListTemplate)?.sections.contains { section in
                section.items.contains { $0 === row }
            } ?? false
        } ?? false
    }

    /// Shuffle All, at the top of a list of songs.
    private func shuffleAllRow(_ action: @escaping () async -> Void) -> CPListItem {
        actionRow(String(localized: "Shuffle All"), symbol: "shuffle", action: action)
    }

    /// Pushes a page once it's built. The row keeps its spinner until then.
    func open(_ make: @escaping () async -> CPListTemplate?, then completion: @escaping () -> Void) {
        Task { [weak self] in
            guard let page = await make(), let self else { return completion() }
            push(page, completion: completion)
        }
    }

    /// A list page, with what to say when it has nothing in it.
    private func page(_ title: String, _ sections: [CPListSection], empty: String) -> CPListTemplate {
        let page = CPListTemplate(title: title, sections: sections)
        page.emptyViewTitleVariants = [empty]
        return page
    }

    /// Play and Shuffle, the first rows of an album, playlist or artist, when there's anything
    /// to play: as Music has them in the car, with the page's name above in the bar. Play
    /// carries the page's line (the artist and year, or how many songs). Rows rather than a
    /// header's buttons, which CarPlay doesn't always pass a tap on from. In the same section
    /// as the songs under them, so the car doesn't open a gap between the two.
    func playRows(detail: String?, play: (() async -> Void)?, shuffle: (() async -> Void)?) -> [CPListItem] {
        var rows: [CPListItem] = []
        if let play {
            let row = actionRow(String(localized: "Play"), symbol: "play.fill", action: play)
            row.setDetailText(detail.flatMap { $0.isEmpty ? nil : $0 })
            rows.append(row)
        }
        if let shuffle {
            rows.append(actionRow(String(localized: "Shuffle"), symbol: "shuffle", action: shuffle))
        }
        return rows
    }

    /// Rows as a section of their own, or none when there are none: above a titled section,
    /// such as an artist's albums.
    static func section(_ rows: [CPListItem]) -> [CPListSection] {
        rows.isEmpty ? [] : [CPListSection(items: rows)]
    }

    /// A row that plays something, with its symbol in Tracks’ red where a cover would be.
    func actionRow(_ title: String, symbol: String, action: @escaping () async -> Void) -> CPListItem {
        let row = CPListItem(text: title, detailText: nil, image: CarPlayImages.symbol(symbol, side: CPListItem.maximumImageSize.height, scale: scale))
        row.handler = { [weak self] _, completion in
            self?.play(action, completion: completion)
        }
        return row
    }

    /// How many rows a page lists, leaving room in the car's limit for Play and Shuffle.
    static var pageRowLimit: Int { max(1, CPListTemplate.maximumItemCount - 2) }

    /// "4 albums · 38 songs".
    static func count(albums: Int, songs: Int) -> String {
        [
            albums > 0 ? String(AttributedString(localized: "^[\(albums) album](inflect: true)").characters) : nil,
            String(AttributedString(localized: "^[\(songs) song](inflect: true)").characters),
        ].compactMap { $0 }.joined(separator: " · ")
    }

    /// A song's length, as "3:41".
    static func length(_ seconds: TimeInterval?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        return Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
    }
}

