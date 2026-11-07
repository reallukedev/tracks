import Foundation
import SwiftData

/// One observed track.
///
/// Not `Sendable`. Hand a ``CaptureSnapshot`` to widgets, the menu bar and the Live Activity.
@Model
public final class Capture {
    // One for each query that runs often enough to matter, matched to its predicate: the
    // history list and widgets (by date), the dedupe check on every poll (song and kind),
    // play-back (kind and date), and the playlist and scrobble queues, which are scoped to
    // this device before anything else.
    #Index<Capture>(
        [\.capturedAt],
        [\.songKey, \.kindRawValue],
        [\.songID, \.kindRawValue],
        [\.kindRawValue, \.capturedAt],
        [\.capturedByDeviceID, \.needsPlaylistWrite],
        [\.capturedByDeviceID, \.scrobbledAt]
    )

    /// The catalog ID we asked for. The playlist may resolve a different ID for the same
    /// recording, which is fine.
    public var songID: String = ""

    /// Identity for dedupe before a catalog ID exists.
    ///
    /// macOS only gets the ID after a catalog search, and radio is polled every 10 seconds,
    /// so deduping on `songID` would let the same track through while the search runs. On
    /// iOS this is the catalog ID.
    public var songKey: String = ""

    /// Counts failed catalog searches so an unidentifiable track stops being retried.
    public var catalogLookupAttempts: Int = 0
    public var title: String = ""
    public var artistName: String = ""
    public var albumTitle: String?
    public var artworkURL: String?

    /// `CaptureKind.rawValue`. Use ``kind`` instead.
    public var kindRawValue: String = CaptureKind.radio.rawValue

    public var capturedAt: Date = Date.distantPast
    /// Which platform observed it, for diagnosing gaps between iPhone and Mac.
    public var platformRawValue: String = CapturePlatform.iOS.rawValue

    /// Cleared once the playlist write succeeds. The retry queue drains on this, so the
    /// write isn't part of the capture transaction.
    public var needsPlaylistWrite: Bool = true
    public var addedToPlaylistAt: Date?
    /// Incremented on each failed write so a permanently bad row stops being retried.
    public var playlistWriteAttempts: Int = 0
    public var lastPlaylistWriteError: String?

    public var playedBackAt: Date?

    /// When Last.fm accepted this. The scrobble queue drains rows where it's nil.
    public var scrobbledAt: Date?
    /// Counts rejections so a track Last.fm will never accept stops being retried.
    public var scrobbleAttempts: Int = 0
    public var lastScrobbleError: String?

    /// The device that recorded this row, which is the only one that writes it to the
    /// playlist. Empty for rows from before sync. See ``DeviceIdentity``.
    public var capturedByDeviceID: String = ""

    /// ``PlaySource`` as its raw value: Apple Music, or Your Music played in Tracks. Use
    /// ``source`` instead.
    ///
    /// Nil for plays kept before Tracks told them apart, and for plays filled in from Apple
    /// Music's Recently Played and Last.fm, which all count as Apple Music. Optional because
    /// CloudKit needs every attribute to be optional or defaulted, and so a store from before
    /// it existed migrates without a stage of its own.
    public var sourceRawValue: String?

    @Relationship(inverse: \Session.captures)
    public var session: Session?

    public init(
        songID: String,
        songKey: String? = nil,
        title: String,
        artistName: String,
        albumTitle: String? = nil,
        artworkURL: String? = nil,
        kind: CaptureKind = .radio,
        capturedAt: Date = .now,
        platform: CapturePlatform = .current,
        deviceID: String = DeviceIdentity.current,
        source: PlaySource? = nil,
        session: Session? = nil
    ) {
        self.songID = songID
        self.songKey = songKey ?? songID
        self.title = title
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.artworkURL = artworkURL
        self.kindRawValue = kind.rawValue
        self.capturedAt = capturedAt
        self.platformRawValue = platform.rawValue
        self.capturedByDeviceID = deviceID
        self.sourceRawValue = source?.rawValue
        // Only radio captures are ever written to the playlist.
        self.needsPlaylistWrite = (kind == .radio)
        self.session = session
    }

    public var kind: CaptureKind {
        get { CaptureKind(rawValue: kindRawValue) ?? .radio }
        set { kindRawValue = newValue.rawValue }
    }

    public var source: PlaySource {
        get { PlaySource(stored: sourceRawValue) }
        set { sourceRawValue = newValue.rawValue }
    }

    public var platform: CapturePlatform {
        get { CapturePlatform(rawValue: platformRawValue) ?? .current }
        set { platformRawValue = newValue.rawValue }
    }
}

public enum CapturePlatform: String, Codable, Sendable {
    case iOS
    case macOS

    public static var current: CapturePlatform {
        #if os(macOS)
        .macOS
        #else
        .iOS
        #endif
    }
}
