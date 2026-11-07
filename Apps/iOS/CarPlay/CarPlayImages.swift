import UIKit
import SwiftUI
import MediaPlayer
import CoreImage.CIFilterBuiltins
import MusicKit
import TracksCore
import CarPlay

/// Pictures for CarPlay's templates, which take finished `UIImage`s rather than views. Covers
/// are fetched and drawn at the car screen's scale, and everything Tracks draws itself (a mix's
/// four covers, a mood's field, Tracks Radio) is the phone's own artwork, rendered, so the car
/// and the phone look like the same app.
@MainActor
enum CarPlayImages {
    /// Finished images by what they show, so rebuilding a tab doesn't draw every cover again.
    /// A few hundred at most, then it starts over.
    private static var cache: [String: UIImage] = [:]

    private static func cached(_ key: String, _ make: () async -> UIImage) async -> UIImage {
        if let image = cache[key] { return image }
        let image = await make()
        if cache.count > 400 {
            cache.removeAll()
            tints.removeAll()
        }
        cache[key] = image
        return image
    }

    // MARK: - Many at once

    /// Pictures for a row of tiles or a list, fetched side by side rather than one after another.
    /// What isn't ready within `wait` gets its stand-in, so a slow connection never holds a tab
    /// up, and arrives through `late` once it is.
    static func batch(
        _ count: Int,
        wait: Duration = .milliseconds(1200),
        standIn: (Int) -> UIImage,
        late: @escaping @MainActor (Int, UIImage) -> Void = { _, _ in },
        _ load: @escaping @MainActor (Int) async -> UIImage
    ) async -> [UIImage] {
        let found = await gather(count, wait: wait, late: late, load)
        return (0..<count).map { found[$0] ?? standIn($0) }
    }

    /// The pictures that arrived within `wait`, by index; the rest come through `late`.
    static func gather(
        _ count: Int,
        wait: Duration,
        late: @escaping @MainActor (Int, UIImage) -> Void,
        _ load: @escaping @MainActor (Int) async -> UIImage?
    ) async -> [Int: UIImage] {
        guard count > 0 else { return [:] }
        let batch = Batch(remaining: count)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            batch.continuation = continuation
            for index in 0..<count {
                Task { @MainActor in
                    let image = await load(index)
                    if batch.isOpen {
                        if let image { batch.images[index] = image }
                        batch.remaining -= 1
                        if batch.remaining == 0 { batch.finish() }
                    } else if let image {
                        late(index, image)
                    }
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: wait)
                batch.finish()
            }
        }
        return batch.images
    }

    /// Where pictures that arrive late go: the tiles or rows they belong to, once those are made.
    @MainActor
    final class Late {
        private var setters: [(UIImage) -> Void] = []
        /// Pictures that arrived before their tiles or rows were made, applied once they are.
        private var pending: [Int: UIImage] = [:]

        func attach(_ elements: [CPListImageRowItemElement]) {
            attach(setters: elements.map { element in { element.image = $0 } })
        }

        func attach(_ rows: [CPListItem]) {
            attach(setters: rows.map { row in { row.setImage($0) } })
        }

        func set(_ index: Int, _ image: UIImage) {
            guard setters.indices.contains(index) else {
                if setters.isEmpty { pending[index] = image }
                return
            }
            setters[index](image)
        }

        private func attach(setters: [(UIImage) -> Void]) {
            self.setters = setters
            for (index, image) in pending where setters.indices.contains(index) {
                setters[index](image)
            }
            pending = [:]
        }
    }

    @MainActor
    private final class Batch {
        var images: [Int: UIImage] = [:]
        var remaining: Int
        var isOpen = true
        var continuation: CheckedContinuation<Void, Never>?

        init(remaining: Int) {
            self.remaining = remaining
        }

        func finish() {
            guard isOpen else { return }
            isOpen = false
            continuation?.resume()
            continuation = nil
        }
    }

    // MARK: - Covers

    /// A cover from the history, or its generated stand-in when it has none or won't load.
    static func cover(url: String?, seed: String, side: CGFloat, scale: CGFloat) async -> UIImage {
        await cached("\(url ?? seed)|\(side)|\(scale)") {
            if let url, let address = URL(string: url),
               let image = await ArtworkImages.shared.image(for: ArtworkImages.Key(url: address, pixels: Int(side * scale))) {
                return UIImage(cgImage: image, scale: scale, orientation: .up)
            }
            return generated(seed: seed, side: side, scale: scale)
        }
    }

    /// A cover from Apple Music. Library covers have an address only MusicKit's own views can
    /// load, so those come from the media library on the phone instead, by name.
    static func cover(_ art: CoverArt, side: CGFloat, scale: CGFloat, album: (title: String, artist: String?)? = nil, playlist: String? = nil) async -> UIImage {
        switch art {
        case .artwork(let artwork):
            let pixels = Int(side * scale)
            let url = artwork.url(width: pixels, height: pixels).flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil }
            let key = "artwork|\(url?.absoluteString ?? "")|\(album?.title ?? "")|\(album?.artist ?? "")|\(playlist ?? "")|\(side)|\(scale)"
            return await cached(key) {
                if let url, let image = await ArtworkImages.shared.image(for: ArtworkImages.Key(url: url, pixels: pixels)) {
                    return UIImage(cgImage: image, scale: scale, orientation: .up)
                }
                // Library covers have an address only MusicKit's own views can load, and some
                // catalog ones don't load at all: the phone's media library by name, then the
                // same album in Apple Music's catalog.
                if let album, let image = LibraryArtwork.album(title: album.title, artist: album.artist, side: side) {
                    return image
                }
                if let playlist, let covers = LibraryArtwork.playlist(named: playlist, side: side / 2), !covers.isEmpty {
                    return drawMosaic(covers, symbol: nil, side: side, scale: scale)
                }
                if let album, let found = await catalogCover(title: album.title, artist: album.artist, pixels: pixels),
                   let address = URL(string: found),
                   let image = await ArtworkImages.shared.image(for: ArtworkImages.Key(url: address, pixels: pixels)) {
                    return UIImage(cgImage: image, scale: scale, orientation: .up)
                }
                return generated(seed: album?.title ?? playlist ?? artwork.alternateText ?? "\(pixels)", side: side, scale: scale)
            }
        case .url(let url, let seed):
            return await cover(url: url, seed: seed, side: side, scale: scale)
        }
    }

    /// A row's cover for something from Apple Music's feed or library.
    static func cover(for item: FeedItem, side: CGFloat, scale: CGFloat) async -> UIImage {
        switch item.content {
        case .album(let album):
            return await cover(item.cover, side: side, scale: scale, album: (album.title, album.artistName))
        case .playlist(let playlist):
            return await cover(item.cover, side: side, scale: scale, playlist: playlist.name)
        case .station, .demoStation:
            return await cover(item.cover, side: side, scale: scale)
        }
    }

    /// An album's cover from Apple Music's catalog, found by its name and artist.
    private static func catalogCover(title: String, artist: String?, pixels: Int) async -> String? {
        var request = MusicCatalogSearchRequest(term: [title, artist].compactMap { $0 }.joined(separator: " "), types: [Album.self])
        request.limit = 5
        guard let albums = try? await request.response().albums else { return nil }
        let match = albums.first { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame }
            ?? albums.first { $0.title.localizedCaseInsensitiveContains(title) || title.localizedCaseInsensitiveContains($0.title) }
        guard let url = match?.artwork?.url(width: pixels, height: pixels), url.scheme?.hasPrefix("http") == true else { return nil }
        return url.absoluteString
    }

    static func generated(seed: String, side: CGFloat, scale: CGFloat) -> UIImage {
        render(GeneratedCover(seed: seed).frame(width: side, height: side), scale: scale)
    }

    // MARK: - Tracks’ own artwork

    /// A mix as the phone draws it: four of its covers to a square, and its symbol in the corner.
    static func mix(_ mix: Mix, side: CGFloat, scale: CGFloat, badged: Bool = true) async -> UIImage {
        let covers = mix.covers
        let symbol = badged ? mix.kind.symbol : nil
        let key = "mix|\(symbol ?? "")|" + covers.prefix(4).map { $0.url ?? $0.seed }.joined(separator: "+") + "|\(side)|\(scale)"
        return await cached(key) {
            guard covers.count >= 4 else {
                let single = await cover(url: covers.first?.url, seed: covers.first?.seed ?? mix.id, side: side, scale: scale)
                return drawMosaic([single], symbol: symbol, side: side, scale: scale)
            }
            // Side by side: four fetches one after another made a mix the slowest card.
            let four = Array(covers.prefix(4))
            async let first = cover(url: four[0].url, seed: four[0].seed, side: side / 2, scale: scale)
            async let second = cover(url: four[1].url, seed: four[1].seed, side: side / 2, scale: scale)
            async let third = cover(url: four[2].url, seed: four[2].seed, side: side / 2, scale: scale)
            async let fourth = cover(url: four[3].url, seed: four[3].seed, side: side / 2, scale: scale)
            return drawMosaic(await [first, second, third, fourth], symbol: symbol, side: side, scale: scale)
        }
    }

    /// Tracks Radio for the car: its colour, and the car large where the radio waves would be.
    /// Without its name, which the car writes itself beside or under it.
    static func tracksRadio(side: CGFloat, scale: CGFloat) async -> UIImage {
        await cached("tracksRadio|\(side)|\(scale)") {
            render(CarRadioTile(side: side), scale: scale)
        }
    }

    /// The colour a card's title sits on: the cover's own, deepened a little so white reads.
    static func tint(for cover: CoverArt) async -> UIColor? {
        guard let color = await CoverTint.color(for: cover) else { return nil }
        return UIColor(color.mix(with: .black, by: 0.25))
    }

    /// A card's colour from its own picture: the picture's average, made rich and deep enough
    /// for white type, as Apple Music colours its cards. Grey pictures stay grey.
    static func tint(of image: UIImage) -> UIColor {
        let id = ObjectIdentifier(image)
        if let known = tints[id] { return known.color }
        let color = averageTint(of: image)
        // Kept with the image, so the identifier can't be taken by another picture.
        tints[id] = (image, color)
        return color
    }

    private static var tints: [ObjectIdentifier: (image: UIImage, color: UIColor)] = [:]
    /// One for every tint: a context is costly to make.
    private static let averaging = CIContext(options: [.workingColorSpace: NSNull()])

    private static func averageTint(of image: UIImage) -> UIColor {
        guard let source = image.cgImage.map(CIImage.init(cgImage:)) else { return .darkGray }
        let filter = CIFilter.areaAverage()
        filter.inputImage = source
        filter.extent = source.extent
        guard let output = filter.outputImage else { return .darkGray }
        var pixel = [UInt8](repeating: 0, count: 4)
        averaging.render(
            output, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil
        )
        let average = UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
        var (hue, saturation, brightness, alpha): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let isGrey = saturation < 0.1
        return UIColor(
            hue: hue,
            saturation: isGrey ? saturation : max(saturation, 0.45),
            brightness: min(max(brightness * 0.7, 0.22), 0.45),
            alpha: 1
        )
    }

    /// A mood as the phone's shelf draws it: its field, and its symbol, here centred and whole
    /// since the car sets the name under it.
    static func mood(_ mood: Mood, side: CGFloat, scale: CGFloat) async -> UIImage {
        await cached("mood|\(mood.rawValue)|\(side)|\(scale)") {
            render(CarMoodTile(mood: mood, side: side), scale: scale)
        }
    }

    /// A genre as the phone's tile draws it: its colour, and its symbol whole in the middle,
    /// as a mood's, since the car sets the name under it.
    static func genre(_ genre: MusicGenre, side: CGFloat, scale: CGFloat) async -> UIImage {
        await cached("genre|\(genre.id)|\(side)|\(scale)") {
            render(CarGenreTile(genre: genre, side: side), scale: scale)
        }
    }

    /// A station's cover with a LIVE tag in its corner, as Apple Music marks its live radio.
    static func live(_ cover: UIImage) -> UIImage {
        let size = cover.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = cover.scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            cover.draw(in: CGRect(origin: .zero, size: size))
            let font = UIFont.systemFont(ofSize: max(8, size.height * 0.15), weight: .heavy)
            let text = NSAttributedString(string: String(localized: "LIVE"), attributes: [.font: font, .foregroundColor: UIColor.white, .kern: 0.5])
            let textSize = text.size()
            let inset = size.height * 0.07
            let pill = CGRect(
                x: inset,
                y: size.height - inset - textSize.height - 2,
                width: textSize.width + textSize.height * 0.7,
                height: textSize.height + 2
            )
            UIColor(TracksRadioArt.color).setFill()
            UIBezierPath(roundedRect: pill, cornerRadius: pill.height / 2).fill()
            text.draw(at: CGPoint(x: pill.minX + textSize.height * 0.35, y: pill.minY + 1))
        }
    }

    /// A symbol in Tracks’ red, centred on a square the size of a row's cover, so rows that
    /// stand for a place (Playlists, Albums) line up with rows that have covers.
    static func symbol(_ name: String, side: CGFloat, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let configuration = UIImage.SymbolConfiguration(pointSize: side * 0.5, weight: .medium)
        let symbol = UIImage(systemName: name, withConfiguration: configuration)?
            .withTintColor(UIColor(TracksRadioArt.color), renderingMode: .alwaysOriginal)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            guard let symbol else { return }
            let origin = CGPoint(x: (side - symbol.size.width) / 2, y: (side - symbol.size.height) / 2)
            symbol.draw(at: origin)
        }
    }

    /// A quiet stand-in while a row's picture loads: a grey tile, or circle for an artist, with
    /// a faint symbol. Neutral on purpose, so it never passes for a real cover.
    static func placeholder(symbol: String, side: CGFloat, scale: CGFloat, round: Bool = false) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        return UIGraphicsImageRenderer(size: rect.size, format: format).image { _ in
            UIColor(white: 0.5, alpha: 0.22).setFill()
            (round ? UIBezierPath(ovalIn: rect) : UIBezierPath(roundedRect: rect, cornerRadius: side * 0.12)).fill()
            let configuration = UIImage.SymbolConfiguration(pointSize: side * 0.36, weight: .medium)
            if let glyph = UIImage(systemName: symbol, withConfiguration: configuration)?
                .withTintColor(UIColor(white: 0.5, alpha: 0.75), renderingMode: .alwaysOriginal) {
                glyph.draw(at: CGPoint(x: rect.midX - glyph.size.width / 2, y: rect.midY - glyph.size.height / 2))
            }
        }
    }

    /// A picture cut to a circle, as Music draws artists.
    static func circle(_ image: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        let rect = CGRect(origin: .zero, size: image.size)
        return UIGraphicsImageRenderer(size: rect.size, format: format).image { _ in
            UIBezierPath(ovalIn: rect).addClip()
            image.draw(in: rect)
        }
    }

    /// An artist's picture from Apple Music, round: the one the phone already found for them,
    /// or the catalog's, by name. Nil when there's none, and the row keeps its stand-in.
    static func artistPicture(named name: String, side: CGFloat, scale: CGFloat, feed: PlayFeed) async -> UIImage? {
        let known = ArtistArtworkCache().urls[StatsCalculator.folded(name)]
        let address: String? = if let known {
            known
        } else if let artwork = await feed.catalogArtist(named: name)?.artwork {
            artwork.url(width: Int(side * scale), height: Int(side * scale))?.absoluteString
        } else {
            nil
        }
        guard let address, let url = URL(string: address), url.scheme?.hasPrefix("http") == true else { return nil }
        return await cached("artist|\(address)|\(side)|\(scale)") {
            guard let image = await ArtworkImages.shared.image(for: ArtworkImages.Key(url: url, pixels: Int(side * scale))) else {
                return placeholder(symbol: "music.microphone", side: side, scale: scale, round: true)
            }
            return circle(UIImage(cgImage: image, scale: scale, orientation: .up))
        }
    }

    /// The ring for Now Playing's button: the song's play count in a faint circle that fills
    /// as the song plays, until it counts, then a check. The count says what the ring is about
    /// at a glance, where an empty circle read as a spinner. Drawn as a template, so the car
    /// colours it as its other buttons.
    static func keepRing(_ status: KeepStatus, plays: Int) -> UIImage {
        let side: CGFloat = 28
        if status == .kept {
            let configuration = UIImage.SymbolConfiguration(pointSize: side * 0.8, weight: .semibold)
            return UIImage(systemName: "checkmark.circle.fill", withConfiguration: configuration)?
                .withRenderingMode(.alwaysTemplate) ?? UIImage()
        }
        guard case .counting(let fill) = status else { return UIImage() }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            let width: CGFloat = 2.4
            let rect = CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: width / 2 + 1, dy: width / 2 + 1)
            let track = UIBezierPath(ovalIn: rect)
            track.lineWidth = width
            UIColor.black.withAlphaComponent(0.3).setStroke()
            track.stroke()
            if fill > 0 {
                let arc = UIBezierPath(
                    arcCenter: CGPoint(x: rect.midX, y: rect.midY),
                    radius: rect.width / 2,
                    startAngle: -.pi / 2,
                    endAngle: -.pi / 2 + 2 * .pi * fill,
                    clockwise: true
                )
                arc.lineWidth = width
                arc.lineCapStyle = .round
                UIColor.black.setStroke()
                arc.stroke()
            }
            // Inside: the plays so far, or a note for a song never heard before.
            let inner = rect.width - width * 2
            if plays > 0 {
                let label = plays < 1000 ? "\(plays)" : "1K+"
                let size: CGFloat = label.count <= 1 ? 12.5 : label.count == 2 ? 11 : 8.5
                let font = UIFont.systemFont(ofSize: size, weight: .bold).rounded
                let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: UIColor.black])
                let bounds = text.boundingRect(with: CGSize(width: inner, height: inner), options: [.usesLineFragmentOrigin], context: nil)
                text.draw(at: CGPoint(x: rect.midX - bounds.width / 2, y: rect.midY - bounds.height / 2))
            } else {
                let configuration = UIImage.SymbolConfiguration(pointSize: 10.5, weight: .bold)
                if let note = UIImage(systemName: "music.note", withConfiguration: configuration)?.withTintColor(.black, renderingMode: .alwaysOriginal) {
                    note.draw(at: CGPoint(x: rect.midX - note.size.width / 2, y: rect.midY - note.size.height / 2))
                }
            }
        }
        return image.withRenderingMode(.alwaysTemplate)
    }

    // MARK: - Drawing

    /// Four tiles in a square (or one filling it), and a symbol in a dark circle in the corner.
    private static func drawMosaic(_ tiles: [UIImage], symbol: String?, side: CGFloat, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            if tiles.count >= 4 {
                for (index, tile) in tiles.prefix(4).enumerated() {
                    let origin = CGPoint(x: CGFloat(index % 2) * side / 2, y: CGFloat(index / 2) * side / 2)
                    tile.draw(in: CGRect(origin: origin, size: CGSize(width: side / 2, height: side / 2)))
                }
            } else if let tile = tiles.first {
                tile.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
            }
            guard let symbol else { return }
            let badge = side * 0.22
            let inset = side * 0.05
            let circle = CGRect(x: inset, y: side - inset - badge, width: badge, height: badge)
            UIColor.black.withAlphaComponent(0.45).setFill()
            context.cgContext.fillEllipse(in: circle)
            let configuration = UIImage.SymbolConfiguration(pointSize: badge * 0.48, weight: .semibold)
            if let glyph = UIImage(systemName: symbol, withConfiguration: configuration)?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                glyph.draw(at: CGPoint(x: circle.midX - glyph.size.width / 2, y: circle.midY - glyph.size.height / 2))
            }
        }
    }

    private static func render(_ view: some View, scale: CGFloat) -> UIImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return renderer.uiImage ?? UIImage()
    }
}

private extension UIFont {
    /// The same font in SF Rounded, as the phone's numbers are drawn.
    var rounded: UIFont {
        guard let descriptor = fontDescriptor.withDesign(.rounded) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

/// Tracks Radio as a station tile: Tracks’ red, lighter in one corner, with rings spreading
/// from the middle like a signal, and the car large at their centre.
private struct CarRadioTile: View {
    let side: CGFloat

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [TracksRadioArt.color.mix(with: .white, by: 0.18), TracksRadioArt.color, TracksRadioArt.color.mix(with: .black, by: 0.18)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // The signal: rings fading as they spread.
            ForEach(1..<4) { ring in
                Circle()
                    .stroke(.white.opacity(0.26 - Double(ring) * 0.06), lineWidth: side * 0.022)
                    .frame(width: side * (0.34 + CGFloat(ring) * 0.2))
            }
            Circle()
                .fill(.white.opacity(0.16))
                .frame(width: side * 0.4)
            Image(systemName: "car.fill")
                .font(.system(size: side * 0.19, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: side, height: side)
        .clipped()
    }
}

/// A mood for the car: the phone's field with the mood's symbol whole in the middle, since the
/// car writes the mood's name under the tile, and a glance needs the shape more than the word.
private struct CarMoodTile: View {
    let mood: Mood
    let side: CGFloat

    var body: some View {
        ZStack {
            MoodField(mood: mood)
            Image(systemName: mood.symbol)
                .font(.system(size: side * 0.36, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.18), radius: side * 0.03, y: side * 0.01)
        }
        .frame(width: side, height: side)
    }
}

/// A genre for the car: its colour lit from the top, and its symbol whole in the middle.
private struct CarGenreTile: View {
    let genre: MusicGenre
    let side: CGFloat

    var body: some View {
        ZStack {
            HueField(color: genre.color)
            Image(systemName: genre.symbol)
                .font(.system(size: side * 0.34, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.18), radius: side * 0.03, y: side * 0.01)
        }
        .frame(width: side, height: side)
    }
}

/// Covers for your Apple Music library, which MusicKit only hands its own views: the same
/// albums and playlists, looked up in the phone's media library by name.
@MainActor
enum LibraryArtwork {
    private static var isAllowed: Bool { MPMediaLibrary.authorizationStatus() == .authorized }

    static func album(title: String, artist: String?, side: CGFloat) -> UIImage? {
        guard isAllowed else { return nil }
        let query = MPMediaQuery.albums()
        query.addFilterPredicate(MPMediaPropertyPredicate(value: title, forProperty: MPMediaItemPropertyAlbumTitle))
        let albums = query.collections ?? []
        let match = albums.first { collection in
            guard let artist else { return true }
            let item = collection.representativeItem
            return item?.albumArtist == artist || item?.artist == artist
        } ?? albums.first
        return match?.representativeItem?.artwork?.image(at: CGSize(width: side, height: side))
    }

    /// Up to four different covers from a playlist's songs, for a mosaic like Apple Music's.
    static func playlist(named name: String, side: CGFloat) -> [UIImage]? {
        guard isAllowed else { return nil }
        let query = MPMediaQuery.playlists()
        query.addFilterPredicate(MPMediaPropertyPredicate(value: name, forProperty: MPMediaPlaylistPropertyName))
        guard let playlist = query.collections?.first else { return nil }
        var seen = Set<String>()
        var covers: [UIImage] = []
        for item in playlist.items {
            let album = item.albumTitle ?? item.title ?? ""
            guard !seen.contains(album), let image = item.artwork?.image(at: CGSize(width: side, height: side)) else { continue }
            seen.insert(album)
            covers.append(image)
            if covers.count == 4 { break }
        }
        // Fewer than four different albums: the first cover alone reads better than a repeat.
        return covers.count >= 4 ? covers : Array(covers.prefix(1))
    }
}

#if DEBUG
extension CarPlayImages {
    /// `-TracksCarPlayArt YES`: draws the car's artwork on one sheet in the app's temporary
    /// folder, CarPlayArt.png, to check it without a car. Debug builds only.
    static func writeSampleSheet(_ model: AppModel) async {
        guard UserDefaults.standard.string(forKey: "TracksCarPlayArt") == "YES" else { return }
        let scale: CGFloat = 2
        let tile = CPListImageRowItemImageGridElement.maximumImageSize.height
        let card = CPListImageRowItemCardElement.maximumFullHeightImageSize
        let row = CPListItem.maximumImageSize.height
        var images: [UIImage] = []
        for each in Mood.allCases { images.append(await mood(each, side: tile, scale: scale)) }
        images.append(await tracksRadio(side: card.height, scale: scale))
        for mix in model.playFeed.mixes.mixes.prefix(3) { images.append(await self.mix(mix, side: card.height, scale: scale)) }
        images.append(live(generated(seed: "Station", side: row, scale: scale)))
        images.append(symbol("music.note.list", side: row, scale: scale))
        images.append(symbol("square.stack", side: row, scale: scale))
        // Now Playing's ring at each stage, white as the car draws it on its dark screen.
        let rings: [(KeepStatus, Int)] = [(.counting(0), 0), (.counting(0.4), 7), (.counting(0.8), 42), (.counting(0.5), 318), (.kept, 43)]
        for (status, plays) in rings {
            let ring = keepRing(status, plays: plays).withTintColor(.white, renderingMode: .alwaysOriginal)
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            images.append(UIGraphicsImageRenderer(size: CGSize(width: 56, height: 56), format: format).image { _ in
                ring.draw(in: CGRect(x: 0, y: 0, width: 56, height: 56))
            })
        }

        let gap: CGFloat = 12
        let width = max(720, images.reduce(gap) { $0 + $1.size.width + gap })
        let lineWidth: CGFloat = 720
        var x = gap, y = gap, lineHeight: CGFloat = 0
        var frames: [CGRect] = []
        for image in images {
            if x + image.size.width + gap > lineWidth { x = gap; y += lineHeight + gap; lineHeight = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: image.size))
            x += image.size.width + gap
            lineHeight = max(lineHeight, image.size.height)
        }
        _ = width
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let sheet = UIGraphicsImageRenderer(size: CGSize(width: lineWidth, height: y + lineHeight + gap), format: format).image { context in
            UIColor(white: 0.07, alpha: 1).setFill()
            context.fill(context.format.bounds)
            for (image, frame) in zip(images, frames) {
                UIBezierPath(roundedRect: frame, cornerRadius: 8).addClip()
                image.draw(in: frame)
                context.cgContext.resetClip()
            }
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "CarPlayArt.png")
        try? sheet.pngData()?.write(to: url)
        print("CarPlay art: tile \(tile), card \(card), row \(row) -> \(url.path)")
    }
}
#endif
