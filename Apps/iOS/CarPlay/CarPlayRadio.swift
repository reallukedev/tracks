import UIKit
import CarPlay
import MusicKit
import TracksCore

/// Radio: everything that plays on its own once started, each a tap from playing. Tracks Radio
/// heads the tab as a station of its own, every mood and your genres sit under it as tiles,
/// Driving first, and Apple's live stations follow.
extension CarPlaySceneDelegate {
    func radioSections() async -> [CPListSection] {
        let feed = model.playFeed
        let player = model.player
        let model = self.model
        var sections = accessSection()

        radioRowState = radioState.rawValue
        if let row = await tracksRadioRow() {
            sections.append(CPListSection(items: [row]))
        }

        // Every mood, as the phone's tiles. Drawn, never fetched, so the tab is never empty.
        let moods = [Mood.drive] + Mood.allCases.filter { $0 != .drive }
        let side = CPListImageRowItemImageGridElement.maximumImageSize.height
        var moodTiles: [CPListImageRowItemImageGridElement] = []
        for mood in moods {
            let image = await CarPlayImages.mood(mood, side: side, scale: scale)
            moodTiles.append(CPListImageRowItemImageGridElement(image: image, imageShape: .roundedRectangle, title: mood.title, accessorySymbolName: nil))
        }
        // On as many lines as they need: CarPlay draws every one, past its usual eight.
        let moodRow = CPListImageRowItem(text: String(localized: "Moods"), imageGridElements: moodTiles, allowsMultipleLines: true)
        moodRow.listImageRowHandler = { [weak self] _, index, completion in
            guard moods.indices.contains(index) else { return completion() }
            let mood = moods[index]
            self?.play({ await MoodPlayback.start(mood, model: model) }, completion: completion)
        }
        sections.append(CPListSection(items: [moodRow]))

        if let genres = await genreSection() {
            sections.append(genres)
        }

        // Apple's stations only play from Apple Music. The cover's LIVE tag says what they
        // are, so a row only has a line when the station has something of its own to say.
        if model.musicSource == .appleMusic, !feed.liveStations.isEmpty {
            let stations = Array(feed.liveStations.prefix(12))
            let rowSide = CPListItem.maximumImageSize.height
            var items: [CPListItem] = []
            let late = CarPlayImages.Late()
            let covers = await CarPlayImages.batch(stations.count, standIn: { _ in
                CarPlayImages.placeholder(symbol: "dot.radiowaves.left.and.right", side: rowSide, scale: self.scale)
            }, late: { index, image in
                late.set(index, stations[index].isLive ? CarPlayImages.live(image) : image)
            }) { [scale] index in
                await CarPlayImages.cover(for: stations[index], side: rowSide, scale: scale)
            }
            for (station, cover) in zip(stations, covers) {
                let line = station.subtitle.flatMap { $0.isEmpty ? nil : $0 }
                let item = CPListItem(text: station.title, detailText: line, image: station.isLive ? CarPlayImages.live(cover) : cover)
                item.isPlaying = isPlaying(station.title)
                item.handler = { [weak self] _, completion in
                    self?.play({ await Self.play(station, player: player) }, completion: completion)
                }
                items.append(item)
            }
            late.attach(items)
            sections.append(CPListSection(items: items, header: String(localized: "Live Radio"), sectionIndexTitle: nil))
        }
        return sections
    }

    /// Redraws Radio when Tracks Radio's row would say something else: it's started, paused,
    /// or become available.
    func refreshRadioIfNeeded() {
        guard radioRowState != radioState.rawValue else { return }
        refreshRadioList()
    }

    private enum RadioState: String {
        case off, idle, playing, paused
    }

    private var radioState: RadioState {
        guard hasTracksRadio else { return .off }
        // By what's playing, not its name: a playlist called Tracks Radio isn't it.
        guard model.player.isPlayingTracksRadio else { return .idle }
        // A song still coming from your server is playing, not paused.
        return model.player.isPlaying || model.player.status == .loading ? .playing : .paused
    }

    /// Tracks Radio as a station: its artwork, and a line that says where it stands, with the
    /// playing marker while it's on. A tap works out what to do then, so it's never a step
    /// behind the music: play it, pick it up where it paused, or show it.
    private func tracksRadioRow() async -> CPListItem? {
        let state = radioState
        guard state != .off else { return nil }
        let image = await CarPlayImages.tracksRadio(side: CPListItem.maximumImageSize.height, scale: scale)
        let line = switch state {
        case .playing: String(localized: "Now Playing")
        case .paused: String(localized: "Paused")
        case .idle, .off: String(localized: "Your station, picked as you drive")
        }
        let row = CPListItem(text: String(localized: "Tracks Radio"), detailText: line, image: image)
        row.isPlaying = state == .playing
        row.handler = { [weak self] _, completion in
            self?.tracksRadioTapped(completion: completion)
        }
        return row
    }

    /// Tracks Radio from a card or a suggestion: picked up where it paused if it's what's on,
    /// otherwise started. Never started over while it plays.
    func startOrResumeTracksRadio() async {
        let player = model.player
        if player.isPlayingTracksRadio {
            if !player.isPlaying { player.togglePlayPause() }
        } else {
            await player.startTracksRadio()
        }
    }

    private func tracksRadioTapped(completion: @escaping () -> Void) {
        let player = model.player
        switch radioState {
        case .playing:
            completion()
            showNowPlaying()
        case .paused:
            player.togglePlayPause()
            completion()
            showNowPlaying()
        case .idle, .off:
            play({ await player.startTracksRadio() }, completion: completion)
        }
    }
}
