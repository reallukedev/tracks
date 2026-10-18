import UIKit
import CarPlay
import MusicKit
import TracksCore

/// Now Playing in the car: CarPlay's own screen, with Tracks’ buttons under the controls, and
/// Up Next as covers that keep up with the queue.
///
/// The buttons change with what's playing, so none is ever there to do nothing:
/// - A queue (an album, a playlist, a mix): Shuffle and Autoplay.
/// - Tracks Radio and Apple's stations pick as they go, so neither.
/// - Then always the ring with the song's play count, filling until it counts, the star for
///   a song from Apple Music's catalog, More Like This on Tracks Radio and the moods, and Not
///   for Me.
///
/// The song's name opens its album, as it does in Music.
extension CarPlaySceneDelegate {
    func configureNowPlaying() {
        let nowPlaying = CPNowPlayingTemplate.shared
        nowPlaying.add(self)
        nowPlaying.isUpNextButtonEnabled = true
        nowPlaying.upNextTitle = String(localized: "Up Next")
        updateNowPlayingButtons()

        // The buttons show what they'd change, so they follow the song, its star, its plays and
        // the settings, and Up Next follows the queue while it's open.
        let player = model.player
        let feed = model.playFeed
        nowPlayingWatch = Task { [weak self] in
            let changes = Observations {
                NowPlayingKey(
                    song: player.current?.id,
                    upNext: player.upNext.map(\.id),
                    isAutoplaying: player.isAutoplaying,
                    autoplay: PlayPreferences.autoplay,
                    context: player.context?.title,
                    kind: player.context.map { "\($0.kind)" },
                    isPlaying: player.isPlaying,
                    isLoading: player.status == .loading,
                    isFavorite: player.current?.song.map(player.isFavorite),
                    plays: player.current.flatMap { feed.facts(for: $0)?.plays },
                    isLive: player.isLive,
                    askedForMore: player.current.map { player.moreLikeThis.contains($0.songIdentity) } ?? false,
                    sharePlay: CarPlaySceneDelegate.sharePlayRowState
                )
            }
            var lastSong: String?
            for await key in changes {
                guard let self else { return }
                if key.song != lastSong {
                    lastSong = key.song
                    // Asked once a song, so the star shows whether it's already a favorite.
                    if let song = player.current?.song, Self.canFavorite(song) { player.lookUpFavorite(song) }
                }
                updateNowPlayingButtons()
                updateKeepTicker()
                refreshRadioIfNeeded()
                if queue != nil { refreshQueue() }
            }
        }
    }

    /// The ring fills with time, which nothing observable says, so it's looked at every second
    /// and redrawn when it's moved on a step: only while a song plays and Now Playing is on the
    /// car's screen, so nothing ticks while it's paused or out of sight.
    func updateKeepTicker() {
        let shouldTick = isNowPlayingShown && model.player.isPlaying && interface != nil
        guard shouldTick != (keepTicker != nil) else { return }
        keepTicker?.cancel()
        keepTicker = nil
        guard shouldTick else { return }
        keepTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                let step = keepStep
                guard step != lastKeepStep else { continue }
                lastKeepStep = step
                updateNowPlayingButtons()
            }
        }
    }

    /// Where the song stands toward counting, now.
    private var keepStatus: KeepStatus? {
        guard let track = model.player.current, let capture = model.capture else { return nil }
        return KeepStatus.of(track, player: model.player, capture: capture)
    }

    /// The ring in twelve steps, so the car's buttons are redrawn a dozen times a song, not
    /// every second.
    private var keepStep: Int {
        switch keepStatus {
        case nil: -2
        case .kept: -1
        case .counting(let fill): Int(fill * 12)
        }
    }

    private struct NowPlayingKey: Equatable {
        let song: String?
        let upNext: [String]
        let isAutoplaying: Bool
        let autoplay: Bool
        let context: String?
        let kind: String?
        let isPlaying: Bool
        /// For Tracks Radio's row in Radio, which counts a song still loading as playing.
        let isLoading: Bool
        let isFavorite: Bool?
        let plays: Int?
        let isLive: Bool
        let askedForMore: Bool
        /// Up Next's SharePlay row, and which of its songs passengers added.
        let sharePlay: String
    }

    /// Whether the star can be given: only a song from Apple Music's catalog has a rating to
    /// change. Library songs carry an id Apple Music's ratings don't take.
    static func canFavorite(_ song: Song) -> Bool {
        !song.id.rawValue.hasPrefix("i.")
    }

    func updateNowPlayingButtons() {
        let player = model.player
        let current = player.current
        let picksAsItGoes = player.isLive || player.context?.isStation == true
        var buttons: [CPNowPlayingButton] = []

        // Shuffle and Autoplay only mean something for a queue. Autoplay takes Repeat's place,
        // since the car has room for five buttons and a queue set to repeat never reaches it.
        if current != nil, !picksAsItGoes {
            buttons.append(CPNowPlayingShuffleButton { _ in player.toggleShuffle() })
            if let image = UIImage(systemName: "infinity") {
                let autoplay = CPNowPlayingImageButton(image: image) { [weak self] _ in
                    player.setAutoplay(!PlayPreferences.autoplay)
                    // A setting, which nothing observed says has changed.
                    self?.updateNowPlayingButtons()
                }
                autoplay.isSelected = PlayPreferences.autoplay
                buttons.append(autoplay)
            }
        }

        // The phone's ring, with the song's plays inside: filling until the song counts, then
        // a check.
        if let current, let status = keepStatus {
            let plays = model.playFeed.facts(for: current)?.plays ?? 0
            let ring = CPNowPlayingImageButton(image: CarPlayImages.keepRing(status, plays: plays)) { [weak self] _ in
                self?.explainKeeping()
            }
            buttons.append(ring)
        }

        // The star, as Music's: a favorite, and in your library, and a live mix plays more
        // like it.
        if let song = current?.song, Self.canFavorite(song) {
            let isFavorite = player.isFavorite(song)
            if let image = UIImage(systemName: isFavorite ? "star.fill" : "star") {
                let star = CPNowPlayingImageButton(image: image) { _ in
                    player.setFavorite(song, !isFavorite)
                }
                star.isSelected = isFavorite
                buttons.append(star)
            }
        }

        // More Like This, beside Not for Me, on Tracks Radio or a mood: the car's way to steer
        // one toward a song. Lit once asked. Not on a queue's Autoplay, whose Shuffle and
        // Autoplay buttons would take the car past its five.
        if let current, player.isLive, player.canAskForMoreLikeThis, let image = UIImage(systemName: "hand.thumbsup") {
            let more = CPNowPlayingImageButton(image: image) { _ in
                player.playMoreLikeThis()
            }
            more.isSelected = player.moreLikeThis.contains(current.songIdentity)
            buttons.append(more)
        }

        // Not for Me: out of the mixes, and on to the next song.
        if let current, let image = UIImage(systemName: "hand.thumbsdown") {
            let notForMe = CPNowPlayingImageButton(image: image) { _ in
                player.setSuggestLess(current.songIdentity, true)
                player.skipToNext()
            }
            buttons.append(notForMe)
        }
        CPNowPlayingTemplate.shared.updateNowPlayingButtons(buttons)
        CPNowPlayingTemplate.shared.isAlbumArtistButtonEnabled = current.map(hasAlbum) ?? false
    }

    /// Whether the song on has an album to open: one from Apple Music, off a station, or one
    /// of yours.
    private func hasAlbum(_ track: PlayerTrack) -> Bool {
        if let local = track.local { return model.yourMusic.index.album(id: local.albumKey) != nil }
        return track.song != nil && track.albumTitle != nil && model.player.context?.isStation != true
    }

    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        // Already open (a second tap before it came up): left as it is.
        if let queue, interface?.templates.contains(where: { $0 === queue }) == true { return }
        let template = CPListTemplate(title: String(localized: "Up Next"), sections: [])
        template.emptyViewTitleVariants = [String(localized: "Nothing Playing")]
        queue = template
        isQueueShown = false
        refreshQueue()
        // Counted as open only once it's on screen: until then a refresh from the watch
        // mustn't take it for closed and stop keeping it current. Deep in a tab, the trail
        // starts again from the tab, under Now Playing.
        push(template) { [weak self] in
            guard let self, queue === template else { return }
            isQueueShown = interface?.templates.contains { $0 === template } == true
        }
    }

    /// The song's name opens its album, as Music's does.
    func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        guard let track = model.player.current else { return }
        Task { [weak self] in
            guard let self else { return }
            let page: CPListTemplate? = if let local = track.local, let album = model.yourMusic.index.album(id: local.albumKey) {
                await localAlbumPage(album)
            } else if let song = track.song, let album = await SongLinks.album(of: song) {
                await appleMusicAlbumPage(album)
            } else {
                nil
            }
            guard let page else { return }
            push(page)
        }
    }

    /// The ring, in words: the song's plays, and when it counts.
    private func explainKeeping() {
        guard let track = model.player.current, let status = keepStatus else { return }
        let plays = model.playFeed.facts(for: track)?.plays ?? 0
        let title = plays == 0
            ? String(localized: "First Listen")
            : String(AttributedString(localized: "^[\(plays) Play](inflect: true)").characters)
        let message: String
        switch status {
        case .kept:
            message = String(localized: "“\(track.title)” is in your listening history.")
        case .counting(let fill):
            let minimum = CaptureSettings().minimumListen(forDuration: track.duration)
            let left = Int((minimum * (1 - fill)).rounded(.up))
            message = left > 0
                ? String(AttributedString(localized: "“\(track.title)” counts toward your history in ^[\(left) second](inflect: true) of listening.").characters)
                : String(localized: "“\(track.title)” counts toward your history as soon as it plays.")
        }
        present(CPActionSheetTemplate(title: title, message: message, actions: [okAction()]))
    }

    /// Up Next with covers: the song playing first, marked, then what's coming. The list is
    /// drawn at once and the covers fill in, so it keeps up with the queue.
    func refreshQueue() {
        guard let queue else { return }
        // Gone from the screen: stop keeping it current.
        if isQueueShown, let interface, !interface.templates.contains(where: { $0 === queue }) {
            self.queue = nil
            isQueueShown = false
            return
        }
        let player = model.player
        let side = CPListItem.maximumImageSize.height
        let standIn = CarPlayImages.placeholder(symbol: "music.note", side: side, scale: scale)
        let sharePlay = SharePlayController.shared
        var covered: [(row: CPListItem, track: PlayerTrack)] = []
        // SharePlay first, where the songs passengers add will go.
        var sections: [CPListSection] = [CPListSection(items: [sharePlayRow()])]
        if let current = player.current {
            let plays = model.playFeed.facts(for: current)?.plays ?? 0
            let detail = plays > 0
                ? String(AttributedString(localized: "\(current.artistName) · ^[\(plays) play](inflect: true)").characters)
                : current.artistName
            let row = CPListItem(text: current.title, detailText: detail, image: standIn)
            row.isPlaying = true
            row.isExplicitContent = current.isExplicit
            // Already on: a tap goes back to it.
            row.handler = { [weak self] _, completion in
                completion()
                self?.popScreen()
            }
            covered.append((row, current))
            sections.append(CPListSection(items: [row], header: String(localized: "Now Playing"), sectionIndexTitle: nil))
        }
        var rows: [CPListItem] = []
        // Room for SharePlay's row and the song playing.
        let limit = max(0, Int(CPListTemplate.maximumItemCount) - 2)
        for track in player.upNext.prefix(min(40, limit)) {
            // Why a live mix picked it, where one thing stands out, as the phone's Up Next says.
            let detail = if sharePlay.isFromSharePlay(track) {
                String(localized: "\(track.artistName) · Added by SharePlay")
            } else if let reason = player.pickReason(for: track) {
                "\(track.artistName) · \(reason.line)"
            } else if player.isAutoplayPick(track) {
                String(localized: "\(track.artistName) · Autoplay")
            } else {
                track.artistName
            }
            let row = CPListItem(text: track.title, detailText: detail, image: standIn)
            row.isExplicitContent = track.isExplicit
            row.handler = { [weak self] _, completion in
                // By the song, not its place: the queue may have moved on since the list opened.
                if let index = player.upNext.firstIndex(where: { $0.id == track.id }) {
                    player.jump(toUpNext: index)
                }
                completion()
                self?.popScreen()
            }
            covered.append((row, track))
            rows.append(row)
        }
        if !rows.isEmpty {
            sections.append(CPListSection(items: rows, header: String(localized: "Up Next"), sectionIndexTitle: nil))
        } else if player.current != nil {
            // Said under the song, rather than an empty page: what happens after it.
            let next = player.context?.isStation == true ? String(localized: "The station picks the next song.")
                : player.isLive || player.isAutoplaying ? String(localized: "Picking the next song…")
                : PlayPreferences.autoplay ? String(localized: "Autoplay picks similar songs after this one.")
                : String(localized: "Nothing else is queued.")
            let row = CPListItem(text: next, detailText: nil)
            row.isEnabled = false
            sections.append(CPListSection(items: [row], header: String(localized: "Up Next"), sectionIndexTitle: nil))
        }
        queue.updateSections(Self.capped(sections))
        let tracks = covered.map(\.track)
        fillImages(covered.map(\.row)) { [weak self] index in
            await self?.cover(for: tracks[index], side: side)
        }
    }

    func cover(for track: PlayerTrack, side: CGFloat) async -> UIImage {
        if let local = track.local {
            return await CarPlayImages.cover(url: model.yourMusic.artworkURL(local.artwork)?.absoluteString, seed: track.albumTitle ?? track.title, side: side, scale: scale)
        }
        return await CarPlayImages.cover(track.cover, side: side, scale: scale, album: track.albumTitle.map { ($0, track.artistName) })
    }
}
