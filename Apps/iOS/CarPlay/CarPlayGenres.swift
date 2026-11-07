import UIKit
import CarPlay
import MusicKit
import TracksCore

/// Genres in the car, in Radio under the moods: the ones you play most as tiles, each a tap
/// from its station (your songs in it and new finds from its charts, picked as it plays). The
/// row's name opens every genre as a list, each a tap from playing too. With your own music,
/// only the genres in it.
extension CarPlaySceneDelegate {
    func genreSection() async -> CPListSection? {
        let all = await genreItems()
        guard !all.isEmpty else { return nil }
        let model = self.model
        // About a line of your genres, as many as the moods above draw in one: the rest are on
        // the list.
        let shown = Array(all.prefix(Self.genreTileCount))
        let side = CPListImageRowItemImageGridElement.maximumImageSize.height
        var tiles: [CPListImageRowItemImageGridElement] = []
        for item in shown {
            let image = await CarPlayImages.genre(item.genre, side: side, scale: scale)
            tiles.append(CPListImageRowItemImageGridElement(image: image, imageShape: .roundedRectangle, title: item.genre.title, accessorySymbolName: nil))
        }
        let row = CPListImageRowItem(text: String(localized: "Genres"), imageGridElements: tiles, allowsMultipleLines: true)
        row.userInfo = Self.contentToken(shown.map(\.genre.id))
        row.listImageRowHandler = { [weak self] _, index, completion in
            guard shown.indices.contains(index) else { return completion() }
            let genre = shown[index].genre
            self?.play({ await GenrePlayback.start(genre, model: model) }, completion: completion)
        }
        row.handler = { [weak self] _, completion in
            guard let self else { return completion() }
            Task {
                let page = await genresPage(all)
                push(page, completion: completion)
            }
        }
        return CPListSection(items: [row])
    }

    /// Every genre as a row with its tile: the ones you play, then the rest.
    private func genresPage(_ items: [GenreTileItem]) async -> CPListTemplate {
        let model = self.model
        let side = CPListItem.maximumImageSize.height
        var yours: [CPListItem] = []
        var more: [CPListItem] = []
        for item in items.prefix(CPListTemplate.maximumItemCount) {
            let genre = item.genre
            let image = await CarPlayImages.genre(genre, side: side, scale: scale)
            let row = CPListItem(text: genre.title, detailText: nil, image: image)
            row.isPlaying = isPlaying(genre.title)
            row.handler = { [weak self] _, completion in
                self?.play({ await GenrePlayback.start(genre, model: model) }, completion: completion)
            }
            // No covers: nothing of yours in it.
            if item.covers.isEmpty { more.append(row) } else { yours.append(row) }
        }
        var sections: [CPListSection] = []
        if !yours.isEmpty {
            sections.append(CPListSection(items: yours, header: String(localized: "Your Genres"), sectionIndexTitle: nil))
        }
        if !more.isEmpty {
            sections.append(CPListSection(items: more, header: yours.isEmpty ? nil : String(localized: "More Genres"), sectionIndexTitle: nil))
        }
        let page = CPListTemplate(title: String(localized: "Genres"), sections: sections)
        page.emptyViewTitleVariants = [String(localized: "No Genres Yet")]
        return page
    }

    static let genreTileCount = 7

    /// Your genres, worked out once for each change to the history or your music: it walks the
    /// whole history, and Radio is redrawn every time Tracks Radio starts or pauses.
    private func genreItems() async -> [GenreTileItem] {
        let key = "\(model.musicSource).\(model.library.revision).\(model.yourMusic.index.tracks.count)"
        if let genres, genres.key == key { return genres.items }
        let items = await GenreShelfItems.load(model: model, facts: model.playFeed.facts)
        genres = (key, items)
        return items
    }
}
