import UIKit
import CarPlay
import MusicKit
import TracksCore

/// Listen Now: a few cards to start from, then a handful of shelves, so the tab is a short scan
/// of pictures rather than of words, as Music's is. Yours come first (what you played, your
/// mixes, your week), then a little of Apple Music's. Each image row carries its own name,
/// which gives it room above and below in the car's list.
extension CarPlaySceneDelegate {
    func listenNowSections() async -> [CPListSection] {
        let feed = model.playFeed
        let player = model.player
        let model = self.model
        listenNow.emptyViewTitleVariants = [String(localized: "Nothing Played Yet")]
        listenNow.emptyViewSubtitleVariants = [String(localized: "Pick a mood in Radio to start. Tracks makes mixes from what you play.")]
        let isAppleMusic = model.musicSource == .appleMusic
        var sections = accessSection()

        // For You: where you left off, Tracks Radio (or Driving, until there's enough
        // listening for it), the mix for right now, and Discover. Square covers on cards of
        // their own colour, as Music's, since a square cover can't fill a tall card without
        // being squashed. Each card has only its name, one line, so they all line up; the For
        // You page has each one's line. Their pictures are fetched side by side.
        var cards: [CarCard] = []
        var carded: Set<String> = []
        let side = CPListImageRowItemCardElement.maximumImageSize.height
        let scale = scale
        // What was playing when Tracks last closed, first: getting in the car is picking up.
        // The car's own Play button can't reach it, since Tracks doesn't hand it to the player
        // until asked, so it doesn't take the audio from another app.
        if let waiting = player.waitingSession?.tracks.first {
            cards.append(CarCard(
                title: String(localized: "Continue"),
                detail: "\(waiting.title) · \(waiting.artistName)",
                image: { [weak self] in await self?.cover(for: waiting, side: side) ?? CarPlayImages.generated(seed: waiting.title, side: side, scale: scale) }
            ) {
                // Only if it's still waiting: resumed some other way since, it's already playing.
                if player.waitingSession != nil { player.togglePlayPause() }
            })
        }
        if hasTracksRadio {
            cards.append(CarCard(
                title: String(localized: "Tracks Radio"),
                detail: String(localized: "Your station, picked as you drive"),
                image: { await CarPlayImages.tracksRadio(side: side, scale: scale) }
            ) { [weak self] in
                await self?.startOrResumeTracksRadio()
            })
        } else {
            // Before Tracks Radio: the mood made for the car.
            cards.append(CarCard(
                title: Mood.drive.title,
                detail: String(localized: "Songs for the road"),
                image: { await CarPlayImages.mood(.drive, side: side, scale: scale) }
            ) { await MoodPlayback.start(.drive, model: model) })
        }
        if let lead = feed.mixes.rightNow ?? feed.mixes.mixes.first {
            cards.append(card(for: lead, side: side))
            carded.insert(lead.id)
        }
        if isAppleMusic, let first = feed.discover.first {
            let art = first.artwork.map(CoverArt.artwork) ?? .url(nil, seed: first.title)
            let songs = feed.discover
            let title = String(localized: "Discover")
            cards.append(CarCard(
                title: title,
                detail: String(localized: "Songs new to you, by artists like the ones you love"),
                image: { await CarPlayImages.cover(art, side: side, scale: scale) }
            ) {
                await player.start(.songs(songs), from: PlayContext(kind: .mix, title: title), shuffled: true)
            })
        }
        for mix in feed.mixes.otherTimes where cards.count < 6 {
            cards.append(card(for: mix, side: side))
            carded.insert(mix.id)
        }
        if !cards.isEmpty {
            let late = CarPlayImages.Late()
            let images = await CarPlayImages.batch(cards.count, wait: .milliseconds(1500), standIn: { index in
                CarPlayImages.generated(seed: cards[index].title, side: side, scale: scale)
            }, late: { index, image in
                late.set(index, image)
            }) { index in
                await cards[index].image()
            }
            let elements = zip(cards, images).map { card, image in
                CPListImageRowItemCardElement(image: image, showsImageFullHeight: false, title: card.title, subtitle: nil, tintColor: CarPlayImages.tint(of: image))
            }
            late.attach(elements)
            let title = String(localized: "For You")
            let row = CPListImageRowItem(text: title, cardElements: elements, allowsMultipleLines: false)
            // What the cards play, so a mix remade under the same name still reloads.
            row.userInfo = Self.contentToken(
                [player.waitingSession?.tracks.first?.id ?? "", "\(hasTracksRadio)"]
                    + feed.mixes.all.flatMap { [$0.id] + $0.songs.map(\.songIdentity) }
                    + feed.discover.map(\.id.rawValue)
            )
            let rows = zip(cards, images).map { card, image in
                CarRow(image: image, title: card.title, detail: card.detail, action: card.action)
            }
            row.listImageRowHandler = { [weak self] _, index, completion in
                guard rows.indices.contains(index) else { return completion() }
                self?.play(rows[index].action, completion: completion)
            }
            // Its name opens it as a list, with each card's whole line.
            row.handler = { [weak self] _, completion in
                self?.openPage(title, rows, completion: completion)
            }
            sections.append(CPListSection(items: [row]))
        }

        if isAppleMusic, let recent = await shelf(String(localized: "Recently Played"), feed.recentlyPlayed) {
            sections.append(recent)
        }

        // The rest of your mixes, each once. With your own music, only the ones enough of
        // whose songs you have.
        let yourMusic = model.yourMusic
        let mixes = feed.mixes.mixes.filter { mix in
            guard !carded.contains(mix.id) else { return false }
            guard !isAppleMusic else { return true }
            return mix.songs.lazy.filter { yourMusic.track(for: HistorySong($0)) != nil }.count >= 5
        }
        if !mixes.isEmpty {
            let rowSide = CPListItem.maximumImageSize.height
            var items: [CPListItem] = []
            let late = CarPlayImages.Late()
            let images = await CarPlayImages.batch(mixes.count, standIn: { _ in
                CarPlayImages.placeholder(symbol: "music.note.list", side: rowSide, scale: scale)
            }, late: { index, image in
                late.set(index, image)
            }) { index in
                await CarPlayImages.mix(mixes[index], side: rowSide, scale: scale)
            }
            for (mix, image) in zip(mixes, images) {
                let item = CPListItem(text: mix.kind.title, detailText: mix.kind.tileLine, image: image)
                item.userInfo = Self.contentToken(mix.songs.map(\.songIdentity))
                item.isPlaying = isPlaying(mix.kind.title)
                let songs = player.songs(in: mix)
                item.handler = { [weak self] _, completion in
                    self?.play({ await player.start(.history(songs), from: PlayContext(kind: .mix, title: mix.kind.title)) }, completion: completion)
                }
                items.append(item)
            }
            late.attach(items)
            sections.append(CPListSection(items: items, header: String(localized: "Your Mixes"), sectionIndexTitle: nil))
        }

        sections += await weekSections()

        // A little of Apple Music's own: two of its picks for you and your artists' new
        // releases. Charts and genre shelves are for browsing, not the road.
        if isAppleMusic {
            for group in feed.recommendations.filter({ !$0.title.isEmpty && $0.items.count >= 3 }).prefix(2) {
                if let picks = await shelf(group.title, group.items) { sections.append(picks) }
            }
            if let releases = await shelf(String(localized: "New from Your Artists"), feed.newReleases) {
                sections.append(releases)
            }
        }
        return sections
    }

    private func card(for mix: Mix, side: CGFloat) -> CarCard {
        let songs = model.player.songs(in: mix)
        let player = model.player
        let scale = scale
        // No symbol in the corner on a card: the card says what it is under the cover. Only
        // the name fits a card; the mix's line is on the For You page.
        return CarCard(title: mix.kind.title, detail: mix.kind.tileLine, image: {
            await CarPlayImages.mix(mix, side: side, scale: scale, badged: false)
        }) {
            await player.start(.history(songs), from: PlayContext(kind: .mix, title: mix.kind.title))
        }
    }

    /// A shelf of albums, playlists or stations: covers with their names under them, a tap
    /// from playing.
    private func shelf(_ title: String, _ all: [FeedItem]) async -> CPListSection? {
        // One line of covers: past that the car keeps the room and draws nothing. The
        // chevron has the rest.
        let items = Array(all.prefix(shelfLength))
        guard items.count >= 3, !title.isEmpty else { return nil }
        let player = model.player
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
        let row = CPListImageRowItem(text: title, imageGridElements: tiles, allowsMultipleLines: false)
        row.userInfo = Self.contentToken(all.map(\.id))
        row.listImageRowHandler = { [weak self] _, index, completion in
            guard items.indices.contains(index) else { return completion() }
            let item = items[index]
            self?.play({ await Self.play(item, player: player) }, completion: completion)
        }
        let listed = Array(all.prefix(CPListTemplate.maximumItemCount))
        let rowSide = CPListItem.maximumImageSize.height
        row.handler = { [weak self] _, completion in
            let rows = listed.map { item in
                CarRow(title: item.title, detail: item.subtitle, cover: { await CarPlayImages.cover(for: item, side: rowSide, scale: scale) }) {
                    await Self.play(item, player: player)
                }
            }
            self?.openPage(title, rows, completion: completion)
        }
        return CPListSection(items: [row])
    }

    // MARK: - Your week

    /// The week's top songs, a tap from playing down the chart, and the artists you've played
    /// most, round as Apple Music draws artists: the stats, as something to play.
    private func weekSections() async -> [CPListSection] {
        let (history, sessions) = (model.library.history, model.library.sessions)
        guard !history.isEmpty else { return [] }
        let (week, artistSongs) = await OffMainActor.run {
            let week = StatsCalculator.summary(range: .week, history: history, sessions: sessions, topLimit: 8)
            // Worked out here, off the main actor, since it walks the whole history.
            let songs = Dictionary(uniqueKeysWithValues: week.topArtists.prefix(6).map {
                ($0.id, Self.mostPlayed(byArtist: $0.id, in: history))
            })
            return (week, songs)
        }
        let player = model.player
        var sections: [CPListSection] = []

        let top = Array(week.topSongs.prefix(min(8, Int(CPMaximumNumberOfGridImages))))
        if top.count >= 3 {
            let songs = week.topSongs.map { HistorySong(songID: $0.songID, title: $0.title, artistName: $0.artistName, albumTitle: $0.albumTitle, artworkURL: $0.artworkURL) }
            let (side, scale) = (CPListImageRowItemRowElement.maximumImageSize.height, scale)
            let late = CarPlayImages.Late()
            let images = await CarPlayImages.batch(top.count, standIn: { index in
                CarPlayImages.generated(seed: top[index].albumTitle ?? top[index].title, side: side, scale: scale)
            }, late: { index, image in
                late.set(index, image)
            }) { index in
                await CarPlayImages.cover(url: top[index].artworkURL, seed: top[index].albumTitle ?? top[index].title, side: side, scale: scale)
            }
            let elements = zip(top, images).map { song, image in
                CPListImageRowItemRowElement(image: image, title: song.title, subtitle: song.artistName)
            }
            late.attach(elements)
            let title = String(localized: "Top Songs This Week")
            let row = CPListImageRowItem(text: title, elements: elements, allowsMultipleLines: false)
            row.listImageRowHandler = { [weak self] _, index, completion in
                self?.play({ await player.start(.history(songs, startingAt: index), from: .songs(title)) }, completion: completion)
            }
            let chart = Array(week.topSongs.prefix(CPListTemplate.maximumItemCount))
            let rowSide = CPListItem.maximumImageSize.height
            row.handler = { [weak self] _, completion in
                let rows = chart.enumerated().map { index, song in
                    let plays = String(AttributedString(localized: "^[\(song.count) play](inflect: true)").characters)
                    return CarRow(title: "\(index + 1). \(song.title)", detail: "\(song.artistName) · \(plays)", cover: {
                        await CarPlayImages.cover(url: song.artworkURL, seed: song.albumTitle ?? song.title, side: rowSide, scale: scale)
                    }) {
                        await player.start(.history(songs, startingAt: index), from: .songs(title))
                    }
                }
                self?.openPage(title, rows, completion: completion)
            }
            sections.append(CPListSection(items: [row]))
        }

        let artists = Array(week.topArtists.prefix(6))
        if artists.count >= 3 {
            let (side, scale) = (CPListImageRowItemCondensedElement.maximumImageSize.height, scale)
            let late = CarPlayImages.Late()
            let images = await CarPlayImages.batch(artists.count, standIn: { _ in
                CarPlayImages.placeholder(symbol: "music.microphone", side: side, scale: scale, round: true)
            }, late: { index, image in
                late.set(index, image)
            }) { index in
                await CarPlayImages.cover(url: artists[index].artworkURL, seed: artists[index].name, side: side, scale: scale)
            }
            let elements = zip(artists, images).map { artist, image in
                let plays = String(AttributedString(localized: "^[\(artist.count) play](inflect: true)").characters)
                return CPListImageRowItemCondensedElement(image: image, imageShape: .circular, title: artist.name, subtitle: plays, accessorySymbolName: nil)
            }
            // Not "On Repeat", which is a mix's name on the cards above.
            late.attach(elements)
            let title = String(localized: "Top Artists This Week")
            let row = CPListImageRowItem(text: title, condensedElements: elements, allowsMultipleLines: false)
            let rowSide = CPListItem.maximumImageSize.height
            row.handler = { [weak self] _, completion in
                let rows = artists.map { artist in
                    let plays = String(AttributedString(localized: "^[\(artist.count) play](inflect: true)").characters)
                    let songs = artistSongs[artist.id] ?? []
                    return CarRow(title: artist.name, detail: "\(plays) · \(Format.listening(artist.listeningSeconds))", cover: {
                        CarPlayImages.circle(await CarPlayImages.cover(url: artist.artworkURL, seed: artist.name, side: rowSide, scale: scale))
                    }) {
                        await player.start(.history(songs), from: PlayContext(kind: .artist, title: artist.name), shuffled: true)
                    }
                }
                self?.openPage(title, rows, completion: completion)
            }
            row.listImageRowHandler = { [weak self] _, index, completion in
                guard artists.indices.contains(index) else { return completion() }
                let artist = artists[index]
                let songs = artistSongs[artist.id] ?? []
                self?.play({ await player.start(.history(songs), from: PlayContext(kind: .artist, title: artist.name), shuffled: true) }, completion: completion)
            }
            sections.append(CPListSection(items: [row]))
        }
        return sections
    }

    /// An artist's songs, most played first, for playing them from the week's row.
    nonisolated private static func mostPlayed(byArtist identity: String, in history: ListeningHistory) -> [HistorySong] {
        var plays: [String: (count: Int, song: HistorySong)] = [:]
        for capture in history.captures where !capture.songID.isEmpty && capture.credits(identity) {
            let song = HistorySong(songID: capture.songID, title: capture.title, artistName: capture.artistName, albumTitle: capture.albumTitle, artworkURL: capture.artworkURL)
            plays[capture.songIdentity] = ((plays[capture.songIdentity]?.count ?? 0) + 1, song)
        }
        return plays.values.sorted { $0.count > $1.count }.prefix(40).map(\.song)
    }

    // MARK: - Pages

    /// A shelf's page: everything on it as rows, each with its whole line, a tap from playing.
    /// It opens at once, and covers not yet drawn fill in as it's looked at.
    func openPage(_ title: String, _ rows: [CarRow], completion: @escaping () -> Void) {
        let standIn = CarPlayImages.placeholder(symbol: "music.note", side: CPListItem.maximumImageSize.height, scale: scale)
        let items = rows.map { row in
            let item = CPListItem(text: row.title, detailText: row.detail, image: row.image ?? standIn)
            item.isPlaying = isPlaying(row.title)
            item.handler = { [weak self] _, completion in
                self?.play(row.action, completion: completion)
            }
            return item
        }
        let page = CPListTemplate(title: title, sections: Self.capped([CPListSection(items: items)]))
        push(page, completion: completion)
        let covers = rows.map(\.cover)
        fillImages(items) { index in
            guard covers.indices.contains(index), let cover = covers[index] else { return nil }
            return await cover()
        }
    }

    // MARK: - Feed items

    /// Plays a station, album or playlist from the feed or the library, whole.
    static func play(_ item: FeedItem, player: PlayerModel) async {
        switch item.content {
        case .station, .demoStation:
            if let (request, context) = item.stationRequest {
                await player.start(request, from: context)
            }
        case .album(let album):
            await player.start(.album(album), from: PlayContext(kind: .album, title: album.title))
        case .playlist(let playlist):
            await player.start(.playlist(playlist), from: PlayContext(kind: .playlist, title: playlist.name))
        }
    }
}

/// A row on a shelf's page: its picture (or how to draw it), its name, its line, and what a
/// tap plays.
struct CarRow {
    var image: UIImage?
    var cover: (@MainActor () async -> UIImage)?
    let title: String
    let detail: String?
    let action: () async -> Void

    init(image: UIImage, title: String, detail: String?, action: @escaping () async -> Void) {
        self.image = image
        self.title = title
        self.detail = detail
        self.action = action
    }

    init(title: String, detail: String?, cover: @escaping @MainActor () async -> UIImage, action: @escaping () async -> Void) {
        self.cover = cover
        self.title = title
        self.detail = detail
        self.action = action
    }
}

/// A card on For You: its name, its whole line for the For You page, how to draw its
/// picture, and what a tap plays.
struct CarCard {
    let title: String
    let detail: String
    let image: @MainActor () async -> UIImage
    let action: () async -> Void
}
