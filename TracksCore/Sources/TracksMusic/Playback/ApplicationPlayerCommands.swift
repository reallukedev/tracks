import Foundation
import MusicKit

/// The application player's async commands, from outside the main actor.
///
/// MusicKit's player isn't `Sendable`, and its async methods aren't isolated to any actor, so
/// the app's main-actor player can't call them on a player it holds without sending it across.
/// Reaching `shared` here, fresh each time, keeps the player out of the app's actor.
public enum ApplicationPlayerCommands {
    public static func play() async throws {
        try await ApplicationMusicPlayer.shared.play()
    }

    /// Readies the queue without playing any of it, so where it starts can be checked first.
    public static func prepare() async throws {
        try await ApplicationMusicPlayer.shared.prepareToPlay()
    }

    public static func skipToNext() async throws {
        try await ApplicationMusicPlayer.shared.skipToNextEntry()
    }

    public static func skipToPrevious() async throws {
        try await ApplicationMusicPlayer.shared.skipToPreviousEntry()
    }

    /// Adds after the current song, or at the end of the queue.
    public static func insert<Item: PlayableMusicItem>(_ items: [Item], next: Bool) async throws {
        try await ApplicationMusicPlayer.shared.queue.insert(items, position: next ? .afterCurrentEntry : .tail)
    }
}
