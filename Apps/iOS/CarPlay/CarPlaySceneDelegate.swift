import UIKit
import CarPlay
import MusicKit
import TracksCore
import TracksMusic

/// Tracks in the car: four tabs made for a glance and one tap, as Music has them, built from
/// CarPlay's own templates so they look and work like the rest of the car.
///
/// - Listen Now leads with large cards (where you left off, Tracks Radio, the mix for right
///   now), then what you played last, your mixes, and your week.
/// - Radio opens on Tracks Radio, then every mood and your genres as tiles, each a tap from
///   playing, then Apple's live stations.
/// - Library opens Playlists, Artists, Albums, Songs and Downloaded as pages, an album or
///   playlist with Play and Shuffle at the top, as Music's do.
/// - Search is Siri, since CarPlay gives music apps a voice rather than a keyboard, and your
///   recent searches from the phone.
///
/// Everything plays through the same player as the phone, so every song is kept. The files
/// beside this one build each tab, Now Playing, and the pictures.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPNowPlayingTemplateObserver, CPTabBarTemplateDelegate, CPInterfaceControllerDelegate {
    var interface: CPInterfaceController?
    var scale: CGFloat = 2
    /// How many covers a shelf shows: one line's worth on this car's screen. The car keeps room
    /// for every cover it's given even when it draws only one line, which left a blank band
    /// under each shelf; the rest are a tap away on the shelf's page.
    var shelfLength = 4
    let model = AppModel.shared
    private var watch: Task<Void, Never>?
    private var connecting: [Task<Void, Never>] = []
    private var refresh: Task<Void, Never>?
    /// The source Search was last drawn for.
    private var searchBuiltFor: MusicSource?
    /// Whether the rebuild waiting to run was asked for at once.
    private var isRebuildingNow = false
    private var radioRefresh: Task<Void, Never>?
    /// Watches the settings the car shows (Tracks Radio on or off, Autoplay), which live in
    /// UserDefaults, where nothing observable says they changed.
    private var settingsObserver: NSObjectProtocol?
    private var shownSettings: (radio: Bool, autoplay: Bool)?
    /// A look at the settings, waiting out a burst of changes.
    private var settingsCheck: Task<Void, Never>?
    private var showsAccessProblem = false
    /// What each tab was last built from, so a tab only reloads when something on it changed.
    /// A reload while someone's scrolling moves the list under their finger.
    private var builtFrom: [ObjectIdentifier: Int] = [:]
    /// What the Library tab was last built for: the source, and Apple Music access or the size
    /// of your own library.
    private var libraryBuiltFor: String?
    /// Up Next while it's open, to keep it current as the queue moves.
    var queue: CPListTemplate?
    var isQueueShown = false
    var nowPlayingWatch: Task<Void, Never>?
    var keepTicker: Task<Void, Never>?
    var lastKeepStep: Int?
    /// Songs added to the library from Now Playing, so its button can show it worked.
    var addedToLibrary: Set<String> = []
    /// Where Tracks Radio stood when Radio was last built, so the tab is redrawn when it changes.
    var radioRowState: String?
    /// SharePlay's page while it's open, what keeps it current, and its code as last drawn.
    var sharePlayPage: CPListTemplate?
    var sharePlayWatch: Task<Void, Never>?
    var sharePlayCode: (invite: SharePlayInvite, image: UIImage)?
    /// A push, pop or sheet under way, so a second tap can't start another inside it.
    var isMoving = false
    var moveID = 0
    /// Whether Now Playing is on screen, for the ring's ticker, which only runs while it is.
    var isNowPlayingShown = false
    /// Your genres as last worked out, and what from, since it walks the whole history.
    var genres: (key: String, items: [GenreTileItem], at: ContinuousClock.Instant)?
    private var listenRefresh: Task<Void, Never>?
    private var libraryRefresh: Task<Void, Never>?
    /// Apple Music access as last read: nil until the car's scene has settled, since it's
    /// never read in a scene callback (see `refreshMusicAccess`).
    private(set) var musicAccess: MusicAuthorization.Status?
    /// Rows that show the playing marker, and how each knows it's the one playing, so the
    /// marker follows the music on pages already open rather than staying where it was drawn.
    private var marked: [(row: WeakRow, isOn: () -> Bool)] = []
    /// Counts pages being built to open, so only the latest tap opens one.
    private var openID = 0
    /// What Now Playing's buttons were last drawn from, so they're only sent again on a change.
    var shownButtons: Int?
    /// What Up Next was last drawn from, for the list open now.
    var shownQueue: Int?

    lazy var listenNow = tab(String(localized: "Listen Now"), symbol: "play.circle.fill")
    lazy var radio = tab(String(localized: "Radio"), symbol: "dot.radiowaves.left.and.right")
    lazy var library = tab(String(localized: "Library"), symbol: "square.stack.fill")
    lazy var search = tab(String(localized: "Search"), symbol: "magnifyingglass")

    // MARK: - Connecting

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        interface = interfaceController
        interfaceController.delegate = self
        scale = interfaceController.carTraitCollection.displayScale
        // About 160 points a cover, beside the car's own side bar and the list's page arrows.
        let width = scene.carWindow.bounds.width
        shelfLength = min(Int(CPMaximumNumberOfGridImages), max(4, Int((width - 150) / 160)))
        configureNowPlaying()
        // Siri, where the car's music apps put it: at the top of Search, or of Library in a car
        // with room for only three tabs.
        let siri = CPAssistantCellConfiguration(position: .top, visibility: .always, assistantAction: .playMedia)
        let hasSearch = CPTabBarTemplate.maximumTabCount >= 4
        if hasSearch {
            search.assistantCellConfiguration = siri
            update(search, searchSections())
        } else {
            library.assistantCellConfiguration = siri
        }
        let tabs = CPTabBarTemplate(templates: hasSearch ? [listenNow, radio, library, search] : [listenNow, radio, library])
        tabs.delegate = self
        interfaceController.setRootTemplate(tabs, animated: false) { _, error in
            if let error { Self.log.error("CarPlay couldn't show its tabs: \(error.localizedDescription, privacy: .public)") }
        }
        // Radio's moods are drawn here, not fetched, so it's never a blank tab while the rest loads.
        refreshRadioList()
        // Apple Music access, once the car has finished connecting. Held back from now even
        // when the car started Tracks and nothing has asked the player to wait yet.
        PlayerQuiet.followScenes()
        connecting.append(Task { [weak self] in
            await PlayerQuiet.settled()
            self?.settingsMayHaveChanged()
        })

        // The car can start Tracks with no phone window, so nothing else has started capture,
        // or listened for SharePlay.
        Task { await model.startCapture() }
        SharePlayController.shared.start(model: model)
        connecting.append(Task { [weak self, model] in
            await model.prepareForPlaying()
            self?.rebuild(after: .zero)
            guard !Task.isCancelled else { return }
            await model.playFeed.loadAppleMusic()
            await model.playFeed.loadFromYourArtists()
            self?.rebuild()
        })
        shownSettings = (PlayPreferences.isTracksRadioOn, PlayPreferences.autoplay)
        showsAccessProblem = needsAppleMusicAccess
        // Only our own defaults, and never on the main queue. With `object: nil` this heard
        // Apple's private iTunesCloud defaults too, and a `.main` observer makes the posting
        // thread wait for the main thread. iTunesCloud posts from the queue that MusicKit's
        // first player call waits on, so the two waited on each other until the scene-update
        // watchdog killed the app as the car connected (0x8BADF00D, Nov 2026).
        settingsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.settingsMayHaveChanged() }
        }
        watch = Task { [weak self] in
            guard let model = self?.model else { return }
            let (feed, library, yourMusic, player) = (model.playFeed, model.library, model.yourMusic, model.player)
            let changes = Observations {
                ContentKey(
                    revision: library.revision,
                    mixes: feed.mixes.all.map(\.id),
                    shelves: (feed.recentlyPlayed + feed.liveStations + feed.newReleases + feed.charts).map(\.id)
                        + feed.recommendations.map(\.id),
                    discover: feed.discover.count,
                    source: model.musicSource,
                    yourMusic: yourMusic.index.tracks.count,
                    yourPlaylists: yourMusic.playlists.all.count,
                    downloads: yourMusic.downloads.items.count,
                    playing: player.context?.title,
                    waiting: player.waitingSession?.tracks.first?.id,
                    captures: model.library.history.captures.count >= 20
                )
            }
            for await _ in changes {
                self?.rebuild()
            }
        }
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        connecting.forEach { $0.cancel() }
        connecting = []
        watch?.cancel()
        refresh?.cancel()
        isRebuildingNow = false
        listenRefresh?.cancel()
        libraryRefresh?.cancel()
        radioRefresh?.cancel()
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        settingsObserver = nil
        settingsCheck?.cancel()
        settingsCheck = nil
        nowPlayingWatch?.cancel()
        keepTicker?.cancel()
        keepTicker = nil
        CPNowPlayingTemplate.shared.remove(self)
        if sharePlayPage != nil { sharePlayPageGone() }
        sharePlayCode = nil
        interface = nil
        isMoving = false
        isNowPlayingShown = false
        queue = nil
        isQueueShown = false
        shownQueue = nil
        shownButtons = nil
        marked = []
        radioRowState = nil
        builtFrom = [:]
        libraryBuiltFor = nil
        searchBuiltFor = nil
    }

    /// Search's recent searches can change on the phone at any time, and nothing says so: they're
    /// read again each time the tab is opened.
    func tabBarTemplate(_ tabBarTemplate: CPTabBarTemplate, didSelect selectedTemplate: CPTemplate) {
        guard selectedTemplate === search else { return }
        update(search, searchSections())
    }

    // MARK: - Screens coming and going

    /// SharePlay's code works while its page is on screen: covered by another screen or popped,
    /// it's hidden, and back on top, shown again. Now Playing's ring only ticks while it's shown.
    func templateWillAppear(_ aTemplate: CPTemplate, animated: Bool) {
        if aTemplate === CPNowPlayingTemplate.shared {
            isNowPlayingShown = true
            updateNowPlayingButtons()
            updateKeepTicker()
        }
        guard let page = sharePlayPage, aTemplate === page else { return }
        SharePlayController.shared.showCode(on: .car)
    }

    func templateDidDisappear(_ aTemplate: CPTemplate, animated: Bool) {
        if aTemplate === CPNowPlayingTemplate.shared {
            isNowPlayingShown = false
            updateKeepTicker()
        }
        guard let page = sharePlayPage, aTemplate === page else { return }
        if interface?.templates.contains(where: { $0 === page }) == true {
            SharePlayController.shared.hideCode(on: .car)
        } else {
            sharePlayPageGone()
        }
    }

    private struct ContentKey: Equatable {
        let revision: Int
        let mixes: [String]
        let shelves: [String]
        let discover: Int
        let source: MusicSource
        let yourMusic: Int
        let yourPlaylists: Int
        let downloads: Int
        /// What's playing, for the rows that show it.
        let playing: String?
        /// The song left paused, for Listen Now's Continue card.
        let waiting: String?
        /// Whether there's enough listening for Tracks Radio.
        let captures: Bool
    }

    private func tab(_ title: String, symbol: String) -> CPListTemplate {
        let template = CPListTemplate(title: title, sections: [])
        template.tabTitle = title
        template.tabImage = UIImage(systemName: symbol)
        template.emptyViewTitleVariants = [String(localized: "Loading…")]
        template.showsSpinnerWhileEmpty = true
        return template
    }

    /// Rebuilds the tabs a moment after the last change, since a capture changes the history,
    /// the mixes and the stats one after another. Each tab on its own, so one waiting on covers
    /// doesn't hold up the others. A tab whose rows came out the same is left alone.
    private func rebuild(after delay: Duration = .milliseconds(500)) {
        // A rebuild asked for at once isn't put off by changes arriving behind it: on
        // connecting, the watch's first look would otherwise hold the tabs back half a second.
        guard interface != nil else { return }
        if isRebuildingNow, delay > .zero { return }
        refresh?.cancel()
        isRebuildingNow = delay == .zero
        refresh = Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            isRebuildingNow = false
            // The recent searches are the source's own. Otherwise Search is read again as it's
            // opened, rather than changing under someone looking at it with every song.
            if searchBuiltFor != model.musicSource {
                searchBuiltFor = model.musicSource
                update(search, searchSections())
            }
            refreshRadioList()
            listenRefresh?.cancel()
            listenRefresh = Task {
                let sections = await listenNowSections()
                guard !Task.isCancelled else { return }
                update(listenNow, sections)
            }
            // The library doesn't change with a capture: once, and again if the source,
            // access, or your own music changes.
            let music = model.yourMusic
            let access = musicAccess.map { "\($0)" } ?? "unknown"
            let key = model.musicSource == .yourMusic
                ? "yourMusic.\(music.index.albums.count).\(music.playlists.all.count).\(music.downloads.items.isEmpty).\(access)"
                : "appleMusic.\(access).\(music.hasMusic)"
            let libraryKey = "\(key).\(model.player.current == nil)"
            guard libraryBuiltFor != libraryKey else { return }
            libraryRefresh?.cancel()
            libraryRefresh = Task {
                // MusicKit's library, only once the car has finished connecting.
                await PlayerQuiet.settled()
                guard !Task.isCancelled else { return }
                let shelves = model.musicSource == .yourMusic ? await yourMusicLibrarySections() : await appleMusicLibrarySections()
                guard !Task.isCancelled else { return }
                library.showsSpinnerWhileEmpty = false
                library.updateSections(Self.capped(sourceSwitchSection().map { [$0] + shelves } ?? shelves))
                libraryBuiltFor = libraryKey
            }
        }
    }

    /// The other source, a tap away at the top of Library, when there's music in both: the song
    /// on carries on from the other source when it has it, so switching while driving doesn't
    /// stop the music.
    private func sourceSwitchSection() -> CPListSection? {
        guard model.isDemoLaunch || (musicAccess == .authorized && model.yourMusic.hasMusic) else { return nil }
        let other: MusicSource = model.musicSource == .appleMusic ? .yourMusic : .appleMusic
        let item = CPListItem(
            text: String(localized: "Switch to \(other.name)"),
            detailText: model.player.current == nil
                ? String(localized: "Now using \(model.musicSource.name)")
                : String(localized: "Carries on with the song playing"),
            image: CarPlayImages.symbol("arrow.left.arrow.right", side: CPListItem.maximumImageSize.height, scale: scale)
        )
        item.handler = { [weak self] _, completion in
            guard let self else { return completion() }
            Task {
                await self.model.switchSourceCarryingOn(to: other)
                completion()
            }
        }
        return CPListSection(items: [item])
    }

    /// Redraws what shows a setting when one the car shows has changed: any change to
    /// UserDefaults lands here, most of them nothing to do with the car.
    private func settingsMayHaveChanged() {
        // Once for a burst: the phone writes its own defaults several times a second while
        // music plays, and each write lands here.
        guard interface != nil, settingsCheck == nil else { return }
        settingsCheck = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            settingsCheck = nil
            checkSettings()
        }
    }

    private func checkSettings() {
        // Apple Music access, turned on in Settings, says nothing either.
        let accessChanged = refreshMusicAccess()
        if needsAppleMusicAccess != showsAccessProblem {
            showsAccessProblem = needsAppleMusicAccess
            rebuild()
        } else if accessChanged {
            rebuild()
        }
        let now = (radio: PlayPreferences.isTracksRadioOn, autoplay: PlayPreferences.autoplay)
        guard let shown = shownSettings, shown != now else { return }
        shownSettings = now
        updateNowPlayingButtons()
        if shown.radio != now.radio { rebuild() }
    }

    /// Reads Apple Music access again, and says whether it changed. Not while a scene is
    /// changing: a MusicKit call made then can wait on the services the car's connection is
    /// still starting, holding the main thread until the watchdog ends the app.
    @discardableResult
    private func refreshMusicAccess() -> Bool {
        guard !PlayerQuiet.isQuiet else { return false }
        let now = MusicAuthorization.currentStatus
        guard now != musicAccess else { return false }
        musicAccess = now
        return true
    }

    /// Radio's list again, on its own: its first row follows Tracks Radio starting and pausing.
    func refreshRadioList() {
        guard interface != nil else { return }
        radioRefresh?.cancel()
        radioRefresh = Task {
            let sections = await radioSections()
            guard !Task.isCancelled else { return }
            update(radio, sections)
        }
    }

    func update(_ template: CPListTemplate, _ sections: [CPListSection]) {
        // Built once: from here an empty tab says why, rather than spinning.
        template.showsSpinnerWhileEmpty = false
        let sections = Self.capped(sections)
        let signature = Self.signature(of: sections)
        guard builtFrom[ObjectIdentifier(template)] != signature else { return }
        builtFrom[ObjectIdentifier(template)] = signature
        template.updateSections(sections)
    }

    /// Sections cut to what CarPlay takes: past its limits it shows only the first anyway, and
    /// the rows a list drops shouldn't be counted on by its handlers.
    static func capped(_ sections: [CPListSection]) -> [CPListSection] {
        var room = Int(CPListTemplate.maximumItemCount)
        var kept: [CPListSection] = []
        for section in sections.prefix(Int(CPListTemplate.maximumSectionCount)) where room > 0 {
            guard section.items.count > room else {
                kept.append(section)
                room -= section.items.count
                continue
            }
            kept.append(CPListSection(items: Array(section.items.prefix(room)), header: section.header, sectionIndexTitle: section.sectionIndexTitle))
            room = 0
        }
        return kept
    }

    /// What a row plays, as a number for its `userInfo`, so a row that reads the same but plays
    /// something new (a mix remade after a song counts) still reloads.
    static func contentToken(_ parts: [String]) -> Int {
        var hasher = Hasher()
        parts.forEach { hasher.combine($0) }
        return hasher.finalize()
    }

    /// What a list shows, as one number: its headers, rows, what they say, which is playing,
    /// and what they play.
    static func signature(of sections: [CPListSection]) -> Int {
        var hasher = Hasher()
        for section in sections {
            hasher.combine(section.header)
            for item in section.items {
                switch item {
                case let row as CPListItem:
                    hasher.combine(row.text)
                    hasher.combine(row.detailText)
                    hasher.combine(row.isPlaying)
                    hasher.combine(row.userInfo as? Int)
                case let row as CPListImageRowItem:
                    hasher.combine(row.text)
                    hasher.combine(row.userInfo as? Int)
                    for element in row.elements {
                        switch element {
                        case let card as CPListImageRowItemCardElement:
                            hasher.combine(card.title)
                            hasher.combine(card.subtitle)
                        case let tile as CPListImageRowItemImageGridElement:
                            hasher.combine(tile.title)
                        case let entry as CPListImageRowItemRowElement:
                            hasher.combine(entry.title)
                            hasher.combine(entry.subtitle)
                        case let person as CPListImageRowItemCondensedElement:
                            hasher.combine(person.title)
                            hasher.combine(person.subtitle)
                        default:
                            break
                        }
                    }
                default:
                    break
                }
            }
        }
        return hasher.finalize()
    }

    /// Whether Tracks Radio is on and has enough of your listening to play from.
    var hasTracksRadio: Bool {
        PlayPreferences.isTracksRadioOn && model.library.history.captures.count >= 20
    }

    /// Whether Apple Music is the source but Tracks can't play from it: asked for from the car,
    /// the prompt would land on a phone no one is looking at.
    var needsAppleMusicAccess: Bool {
        guard let musicAccess else { return false }
        return !model.isDemoLaunch && model.musicSource == .appleMusic && musicAccess != .authorized
    }

    /// Said at the top of a tab when nothing from Apple Music can play, rather than on every
    /// tap: what's wrong, and what fixes it.
    func accessSection() -> [CPListSection] {
        guard needsAppleMusicAccess else { return [] }
        let problem = PlayerProblem.accessDenied
        let row = CPListItem(text: problem.title, detailText: problem.message, image: CarPlayImages.symbol("exclamationmark.triangle.fill", side: CPListItem.maximumImageSize.height, scale: scale))
        row.handler = { [weak self] _, completion in
            completion()
            self?.show(problem)
        }
        return [CPListSection(items: [row])]
    }

    /// Whether what's playing came from here: a mix, mood or station by its name.
    func isPlaying(_ title: String) -> Bool {
        model.player.hasQueue && model.player.context?.title == title
    }

    /// Shows the playing marker on a row while `isOn` says so, now and as the music moves on.
    func mark(_ row: CPListItem, _ isOn: @escaping () -> Bool) {
        row.isPlaying = isOn()
        if marked.count > 400 { marked.removeAll { $0.row.value == nil } }
        marked.append((WeakRow(value: row), isOn))
    }

    /// Marks the row of what's playing now, wherever one is open, and unmarks the rest.
    func refreshPlayingMarks() {
        marked.removeAll { $0.row.value == nil }
        for (box, isOn) in marked {
            guard let row = box.value else { continue }
            let on = isOn()
            if row.isPlaying != on { row.isPlaying = on }
        }
    }

    /// Whether the song playing is this one from Apple Music.
    func isPlayingSong(_ id: MusicItemID) -> Bool {
        model.player.current?.song?.id == id
    }

    /// Whether the song playing is this one of yours.
    func isPlayingTrack(_ id: LocalTrack.ID) -> Bool {
        model.player.current?.local?.id == id
    }

    // MARK: - Playing

    /// Plays, then shows Now Playing, or says what went wrong, in the car: no one should need
    /// the phone to find out.
    func play(_ action: @escaping () async -> Void, completion: @escaping () -> Void) {
        // Asking for Apple Music access from the car would put a prompt on a phone no one is
        // looking at, and leave the row spinning. Decided here, not from a problem left over
        // from the phone, which would otherwise stop every row playing.
        let needsAccess = needsAppleMusicAccess
        model.player.problem = needsAccess ? .accessDenied : nil
        Task { [weak self] in
            if !needsAccess { await action() }
            completion()
            guard let self else { return }
            if let problem = model.player.problem {
                model.player.problem = nil
                show(problem)
            } else {
                showNowPlaying()
            }
        }
    }

    /// A problem in a sheet with what went wrong and what to do, since the car's alert only
    /// has room for a title.
    func show(_ problem: PlayerProblem) {
        present(CPActionSheetTemplate(title: problem.title, message: problem.message, actions: [okAction()]))
    }

    /// Pushes a page once it's built. The row keeps its spinner until then. Only the latest
    /// tap opens its page: two rows tapped in a row would otherwise stack both pages.
    func open(_ make: @escaping () async -> CPListTemplate?, then completion: @escaping () -> Void) {
        openID &+= 1
        let id = openID
        Task { [weak self] in
            let page = await make()
            guard let self, let page, openID == id else { return completion() }
            push(page, completion: completion)
        }
    }
}

/// A row held without keeping it: a page gone from the car takes its rows with it.
struct WeakRow {
    weak var value: CPListItem?
}

