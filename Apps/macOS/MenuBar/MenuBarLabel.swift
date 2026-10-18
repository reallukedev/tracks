import SwiftUI
import AppKit
import TracksCore

/// The status item itself: symbol, album cover, text, or a format the user wrote.
///
/// A `MenuBarExtra` label is rendered into the status item, so keep it to an `Image` and a
/// `Text`. Don't use `AsyncImage`: it would reload on every redraw. ``MenuBarArtwork`` loads
/// the cover once per URL.
struct MenuBarLabel: View {
    /// What is audible now. Present from a song's first second, before it has been captured.
    let nowPlaying: NowPlaying?
    /// Fallback for the moment before the first poll answers, and while nothing is playing.
    let lastCapture: CaptureSnapshot?
    let isCapturing: Bool
    /// Nil until the first poll. See ``CaptureService/isSomethingPlaying``.
    let isPlaying: Bool?

    /// The song playing now, otherwise the last capture.
    private var song: (title: String, artistName: String, albumTitle: String?)? {
        if let nowPlaying {
            return (nowPlaying.title, nowPlaying.artistName, nowPlaying.albumTitle)
        }
        if let lastCapture {
            return (lastCapture.title, lastCapture.artistName, lastCapture.albumTitle)
        }
        return nil
    }
    let style: MenuBarLabelStyle
    let format: String
    let animates: Bool

    @Environment(MenuBarArtwork.self) private var artwork
    /// Always wins over the app's own animation setting.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            icon
            if let text, !text.isEmpty {
                Text(text)
            }
        }
        // Keyed on the song, so the label only cross-fades when the track changes.
        .id(song?.title ?? "")
        .transition(.opacity)
        .animation(motion, value: song?.title)
        // VoiceOver reads the label as one sentence.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// Menu bar content is 18pt tall. Larger artwork gets clipped.
    private static let artworkSize: CGFloat = 18



    /// Nil when motion is off, which is what `.animation(nil, value:)` wants.
    private var motion: Animation? {
        guard animates, !reduceMotion else { return nil }
        return .easeInOut(duration: 0.28)
    }

    /// Whether to name a song at all. With nothing playing the label is just the symbol.
    /// Unknown counts as playing, so the label doesn't blank at launch.
    private var showsSong: Bool { isPlaying != false }

    @ViewBuilder
    private var icon: some View {
        if !showsSong {
            Image(systemName: style.symbol(isCapturing: isCapturing) ?? MenuBarLabelStyle.fallbackSymbol)
        } else if style.showsArtwork, let cover = artwork.image {
            // Corners are rounded into the image; see `MenuBarArtwork.rounded`. Sized from
            // the image because it may include `MenuBarArtwork.trailingGap`.
            Image(nsImage: cover)
                .resizable()
                .frame(width: cover.size.width, height: cover.size.height)
        } else if style.showsArtwork, song != nil {
            // Loading, or no artwork. Holds the cover's space so the label doesn't jump.
            RoundedRectangle(cornerRadius: MenuBarArtwork.corner, style: .continuous)
                .fill(.quaternary)
                .frame(width: Self.artworkSize, height: Self.artworkSize)
        } else if let symbol = style.symbol(isCapturing: isCapturing) {
            Image(systemName: symbol)
        } else if text?.isEmpty != false {
            // A text style with no text yet would leave an invisible, unclickable item.
            Image(systemName: MenuBarLabelStyle.fallbackSymbol)
        }
    }

    private var text: String? {
        guard showsSong, let song else { return nil }
        return switch style {
        case .radio, .note, .artwork: nil
        case .title: MenuBarLabelFormat.render("{title}", title: song.title, artist: song.artistName)
        case .artist: MenuBarLabelFormat.render("{artist}", title: song.title, artist: song.artistName)
        case .artworkAndTitle: MenuBarLabelFormat.render("{title}", title: song.title, artist: song.artistName)
        case .custom: MenuBarLabelFormat.render(
            format,
            title: song.title,
            artist: song.artistName,
            album: song.albumTitle
        )
        }
    }

    private var accessibilityText: String {
        guard showsSong else {
            return isCapturing ? "Tracks, nothing playing" : "Tracks, capture paused"
        }
        guard let song else {
            return isCapturing ? "Tracks, capturing" : "Tracks, capture paused"
        }
        return "Tracks, \(song.title) by \(song.artistName)"
    }
}

/// Loads the album cover for the status item, once per URL. Lives outside the view because
/// the label is rebuilt constantly.
@MainActor
@Observable
final class MenuBarArtwork {
    /// Menu bar content height. Set on the image, since that's what the status item measures.
    static let pointSide: CGFloat = 18

    /// Roughly Apple's corner proportion for small artwork.
    static let corner: CGFloat = 4

    /// How long the previous cover may stay up while the next one downloads. Most fetches
    /// finish inside this, so there's no placeholder flicker; much longer and the new title
    /// sits next to the old cover.
    static let staleCoverGrace: Duration = .milliseconds(500)

    /// Transparent space drawn to the right of the cover when a title follows it.
    ///
    /// The status item lays out the image and text itself with a fixed 3pt gap, ignoring
    /// `HStack(spacing:)` and `.padding(.trailing:)` (spacing 6 and 12 rendered the same).
    /// The only way to widen it is inside the image; this makes it 7pt.
    static let trailingGap: CGFloat = 4

    private(set) var image: NSImage?
    private var loadedURL: String?
    private var loadedGap: CGFloat = 0
    /// The downloaded cover before rounding, so changing the gap doesn't refetch it.
    private var source: NSImage?
    private var task: Task<Void, Never>?

    /// Redraws the cover at menu bar size with its corners rounded into the image. A SwiftUI
    /// `clipShape` doesn't survive rendering into the status item; the cover comes out square.
    ///
    /// `NSImage.size` is in points and the status item measures the image, not the SwiftUI
    /// frame, so it must be the size to draw at. The drawing handler runs at device
    /// resolution, so the result stays sharp.
    static func rounded(_ image: NSImage, trailingGap: CGFloat = 0) -> NSImage {
        let side = pointSide
        return NSImage(size: NSSize(width: side + trailingGap, height: side), flipped: false) { _ in
            NSGraphicsContext.current?.imageInterpolation = .high
            // The cover fills the leading square; the rest is the transparent gap.
            let rect = NSRect(x: 0, y: 0, width: side, height: side)
            NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner).addClip()
            image.draw(
                in: rect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high.rawValue]
            )
            return true
        }
    }

    /// Call when the capture or the style changes. A no-op when neither has.
    ///
    /// - Parameter trailingGap: space to leave to the right of the cover, for the styles that
    ///   draw a title after it.
    func load(_ urlString: String?, trailingGap: CGFloat = 0) {
        if urlString == loadedURL, trailingGap == loadedGap { return }

        // Only the gap changed, so the download does not need repeating.
        if urlString == loadedURL, let source {
            loadedGap = trailingGap
            image = MenuBarArtwork.rounded(source, trailingGap: trailingGap)
            return
        }

        loadedURL = urlString
        loadedGap = trailingGap
        task?.cancel()

        guard let urlString, let url = URL(string: urlString) else {
            source = nil
            image = nil
            return
        }
        task = Task { [weak self] in
            // The cover on screen is the previous song's. Clear it if the fetch takes
            // longer than the grace period.
            let stale = Task { [weak self] in
                try? await Task.sleep(for: MenuBarArtwork.staleCoverGrace)
                guard !Task.isCancelled else { return }
                self?.image = nil
            }
            defer { stale.cancel() }

            guard let data = try? await URLSession.shared.data(from: url).0,
                  let loaded = NSImage(data: data)
            else {
                // Show the placeholder, not the last song's cover.
                self?.image = nil
                return
            }
            guard !Task.isCancelled else { return }
            self?.source = loaded
            self?.image = MenuBarArtwork.rounded(loaded, trailingGap: trailingGap)
        }
    }
}
