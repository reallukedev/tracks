import Foundation
import AppKit
import TracksCore
import TracksMusic

/// Dumps everything macOS reports about the current track, from two sources:
///
/// - The `com.apple.Music.playerInfo` notification needs no permission but carries no
///   catalog id or station name.
/// - Music.app scripting has `current stream title` and `current stream URL`, but its
///   `current track` reads have failed for streamed and autoplayed tracks (radio) since
///   macOS 26, so every read is logged with its error.
@MainActor
final class PlatformProbeSampler {
    private var playerInfoSource: PlayerInfoSource?
    private var lastScriptingFingerprint: String?

    func environmentRows() -> [(key: String, value: String)] {
        [
            ("Music.app running", String(MusicScripting.isMusicRunning)),
            ("Observing notification", MusicNotificationName.preferred),
            ("Duplicate (not observed)", MusicNotificationName.legacyDuplicate),
        ]
    }

    func start(log: ProbeLog) {
        guard playerInfoSource == nil else { return }

        // Registered with .deliverImmediately. With the default, .coalesce, delivery is
        // suspended while the app is inactive, which for a menu bar app is nearly always.
        let source = PlayerInfoSource { userInfo in
            Task { @MainActor in
                log.append(
                    .playerInfo,
                    "playerInfo fired",
                    fields: ProbeFormat.dictionary(userInfo, expectedKeys: PlayerInfoKey.all)
                )
            }
        }
        source.start()
        playerInfoSource = source

        log.append(.environment, "Started macOS sampling", fields: [
            ("suspensionBehavior", "deliverImmediately"),
            ("note", "Music posts the same event under both names; only one is observed."),
        ])
    }

    func stop() {
        playerInfoSource?.stop()
        playerInfoSource = nil
        lastScriptingFingerprint = nil
    }

    /// macOS exposes no catalog id (`Store URL` belongs to the iTunes Library XML export,
    /// not the notification), so this runs the same pipeline as the app: read metadata from
    /// Music.app, then match it with a catalog search.
    func resolveCurrentSong() async -> SongResolution {
        guard MusicScripting.isMusicRunning else {
            return .unavailable("Music.app is not running.")
        }

        let title = MusicScripting.read("name of current track")
        let artist = MusicScripting.read("artist of current track")
        let durationReading = MusicScripting.read("duration of current track")
        let albumReading = MusicScripting.read("album of current track")

        var diagnostics: [(key: String, value: String)] = [
            ("name of current track", title.value ?? "‹error: \(title.errorDescription ?? "?")›"),
            ("artist of current track", artist.value ?? "‹error: \(artist.errorDescription ?? "?")›"),
            ("duration of current track", durationReading.value ?? "‹error: \(durationReading.errorDescription ?? "?")›"),
            ("album of current track", albumReading.value ?? "‹error: \(albumReading.errorDescription ?? "?")›"),
        ]

        guard let name = title.value, let artistName = artist.value,
              !name.isEmpty, !artistName.isEmpty
        else {
            // Expected on radio: -1728 is the macOS 26 bug for streamed and autoplayed tracks.
            diagnostics.append(("note", "Music.app would not report the current track. Error -1728 is the known macOS 26+ bug for streamed tracks (FB19908171)."))
            return SongResolution(songID: nil, method: "AppleScript metadata read failed", diagnostics: diagnostics)
        }

        // Scripting reports duration in seconds; the notification's Total Time is in
        // milliseconds. Neither is there for radio, so album is the only tiebreaker left.
        let duration = durationReading.value.flatMap(Double.init)
        let album = albumReading.value.flatMap { $0 == "missing value" ? nil : $0 }
        let query = CatalogQuery(
            title: name,
            artistName: artistName,
            duration: duration,
            albumTitle: album
        )
        diagnostics.append(("search term", query.searchTerm))

        do {
            let match = try await CatalogLookup().resolve(query)
            diagnostics.append(
                ("match", match.map { "\($0.id): \($0.title) / \($0.albumTitle ?? "?")" }
                    ?? "‹no confident match, rejected rather than guessed›")
            )
            return SongResolution(
                songID: match?.id,
                method: "catalog search matched on title + artist + album",
                diagnostics: diagnostics
            )
        } catch {
            diagnostics.append(("search error", String(describing: error)))
            return SongResolution(songID: nil, method: "catalog search failed", diagnostics: diagnostics)
        }
    }

    func sample(into log: ProbeLog) {
        guard MusicScripting.isMusicRunning else { return }

        let readings = MusicScripting.readAll()
        let fingerprint = readings.map { "\($0.property)=\($0.value ?? $0.errorDescription ?? "")" }
            .joined(separator: "|")
        guard fingerprint != lastScriptingFingerprint else { return }
        lastScriptingFingerprint = fingerprint

        let fields = readings.map { reading in
            (key: reading.property, value: reading.value ?? "‹error: \(reading.errorDescription ?? "unknown")›")
        }
        let failures = readings.filter { !$0.succeeded }.count
        log.append(
            .scripting,
            failures == 0
                ? "Music scripting read"
                : "Music scripting read (\(failures) of \(readings.count) failed)",
            fields: fields
        )
    }
}
