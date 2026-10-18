import Foundation
import MusicKit
import MediaPlayer
import TracksCore
import TracksMusic

/// Dumps everything iOS reports about the current track, to find fields that separate radio
/// from on-demand. `MusicPlayer.Queue.Entry.Item` has no `.station` case, so the candidates
/// are `isTransient`, the encoded `playParameters` and the `MPMediaItem` flags.
@MainActor
final class PlatformProbeSampler {
    /// Only log when something changed, so track transitions stand out.
    private var lastFingerprint: String?

    func environmentRows() -> [(key: String, value: String)] {
        [
            ("MPMediaLibrary authorization", String(describing: MPMediaLibrary.authorizationStatus())),
            ("Queue affects listening history", String(SystemMusicPlayer.shared.queue.affectsListeningHistory)),
        ]
    }

    func start(log: ProbeLog) {
        MPMusicPlayerController.systemMusicPlayer.beginGeneratingPlaybackNotifications()
        log.append(.environment, "Started iOS sampling")
    }

    func stop() {
        MPMusicPlayerController.systemMusicPlayer.endGeneratingPlaybackNotifications()
        lastFingerprint = nil
    }

    /// iOS hands us a catalog ID directly, so no search is needed.
    func resolveCurrentSong() async -> SongResolution {
        if case .song(let song) = SystemMusicPlayer.shared.queue.currentEntry?.item {
            return SongResolution(
                songID: song.id.rawValue,
                method: "SystemMusicPlayer queue entry",
                diagnostics: [("title", song.title), ("artist", song.artistName)]
            )
        }
        // MediaPlayer sometimes has a catalog id when MusicKit doesn't. "0" is its
        // placeholder for a library-only item.
        let item = MPMusicPlayerController.systemMusicPlayer.nowPlayingItem
        if let storeID = item?.playbackStoreID, !storeID.isEmpty, storeID != "0" {
            return SongResolution(
                songID: storeID,
                method: "MPMediaItem.playbackStoreID",
                diagnostics: [("title", ProbeFormat.value(item?.title))]
            )
        }
        return .unavailable("No catalog ID from either SystemMusicPlayer or MediaPlayer.")
    }

    func sample(into log: ProbeLog) {
        let player = SystemMusicPlayer.shared
        let entry = player.queue.currentEntry
        let item = MPMusicPlayerController.systemMusicPlayer.nowPlayingItem

        let fingerprint = [entry?.id, item?.playbackStoreID, item?.title].map { $0 ?? "-" }.joined(separator: "|")
        guard fingerprint != lastFingerprint else { return }
        lastFingerprint = fingerprint

        log.append(.systemPlayer, "Queue entry changed", fields: systemPlayerFields(player: player, entry: entry))
        log.append(.mediaPlayer, "Now playing item", fields: mediaPlayerFields(item: item))
    }

    private func systemPlayerFields(
        player: SystemMusicPlayer,
        entry: MusicKit.MusicPlayer.Queue.Entry?
    ) -> [(key: String, value: String)] {
        var fields: [(key: String, value: String)] = [
            ("playbackStatus", String(describing: player.state.playbackStatus)),
            ("playbackRate", String(player.state.playbackRate)),
            ("repeatMode", ProbeFormat.value(player.state.repeatMode)),
            ("shuffleMode", ProbeFormat.value(player.state.shuffleMode)),
            ("playbackTime", String(format: "%.1f", player.playbackTime)),
            // The system player's queue only exposes `currentEntry`; `entries` is
            // ApplicationMusicPlayer only.
            ("queue.affectsListeningHistory", String(player.queue.affectsListeningHistory)),
        ]

        guard let entry else {
            fields.append(("currentEntry", "‹nil›"))
            return fields
        }

        fields.append(contentsOf: [
            ("entry.id", entry.id),
            ("entry.title", entry.title),
            ("entry.subtitle", ProbeFormat.value(entry.subtitle)),
            // Radio queues are server-driven, so this may flag a station.
            ("entry.isTransient", String(entry.isTransient)),
            ("entry.transientItem", entry.transientItem.map { String(describing: type(of: $0)) } ?? "‹nil›"),
            ("entry.startTime", ProbeFormat.value(entry.startTime)),
            ("entry.endTime", ProbeFormat.value(entry.endTime)),
        ])

        switch entry.item {
        case .song(let song):
            fields.append(("item.case", "song"))
            fields.append(("song.id", song.id.rawValue))
            fields.append(("song.title", song.title))
            fields.append(("song.artistName", song.artistName))
            fields.append(("song.albumTitle", ProbeFormat.value(song.albumTitle)))
            fields.append(("song.duration", ProbeFormat.value(song.duration)))
            fields.append(("song.isrc", ProbeFormat.value(song.isrc)))
        case .musicVideo(let video):
            fields.append(("item.case", "musicVideo"))
            fields.append(("musicVideo.id", video.id.rawValue))
        case .none:
            fields.append(("item.case", "‹nil: entry has no resolved item›"))
        @unknown default:
            fields.append(("item.case", "‹unknown case, new in this OS›"))
        }

        // PlayParameters has no public members but is Codable, and for stations the payload
        // is thought to carry `kind: "radioStation"`. Encoding it is the only way to look.
        if let parameters = entry.item?.playParameters {
            fields.append(("item.playParameters", ProbeFormat.json(parameters)))
        } else {
            fields.append(("item.playParameters", "‹nil›"))
        }

        return fields
    }

    private func mediaPlayerFields(item: MPMediaItem?) -> [(key: String, value: String)] {
        let controller = MPMusicPlayerController.systemMusicPlayer
        var fields: [(key: String, value: String)] = [
            ("playbackState", String(describing: controller.playbackState)),
            ("indexOfNowPlayingItem", String(controller.indexOfNowPlayingItem)),
            ("repeatMode", String(describing: controller.repeatMode)),
            ("shuffleMode", String(describing: controller.shuffleMode)),
        ]

        guard let item else {
            // Worth noting if this happens during radio.
            fields.append(("nowPlayingItem", "‹nil›"))
            return fields
        }

        fields.append(contentsOf: [
            ("title", ProbeFormat.value(item.title)),
            ("artist", ProbeFormat.value(item.artist)),
            ("albumTitle", ProbeFormat.value(item.albumTitle)),
            ("albumArtist", ProbeFormat.value(item.albumArtist)),
            ("genre", ProbeFormat.value(item.genre)),
            ("playbackStoreID", item.playbackStoreID),
            ("persistentID", String(item.persistentID)),
            ("mediaType", String(item.mediaType.rawValue)),
            ("isCloudItem", String(item.isCloudItem)),
            ("hasProtectedAsset", String(item.hasProtectedAsset)),
            ("playbackDuration", String(format: "%.1f", item.playbackDuration)),
            ("isExplicitItem", String(item.isExplicitItem)),
            ("releaseDate", ProbeFormat.value(item.releaseDate)),
            ("artwork", item.artwork == nil ? "‹nil›" : "present"),
        ])
        return fields
    }
}
