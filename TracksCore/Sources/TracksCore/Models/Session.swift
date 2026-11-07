import Foundation
import SwiftData

/// Contiguous listening to one station.
///
/// Closed after ``SessionPolicy/silenceTimeout`` of no activity, or immediately on a
/// station change. Sessions surface in the Mac menu bar and drive statistics; the main
/// window's History groups by day and station, never by session.
@Model
public final class Session {
    // The lookups that run on every observation: this device's open session, and the recent
    // sessions the menu bar lists.
    #Index<Session>([\.endedAt], [\.startedAt], [\.deviceID, \.endedAt])

    public var startedAt: Date = Date.distantPast
    /// Nil while the session is open.
    public var endedAt: Date?
    /// Last time a track was observed. Drives the silence timeout.
    public var lastActivityAt: Date = Date.distantPast

    /// The device listening, which is the only one that extends or closes the session.
    ///
    /// Sessions sync, so without this the Mac and iPhone listening at the same time each
    /// found the other's open session, called it a station change or a silence, and closed
    /// it. Nil for sessions from before this existed; those count as every device's own, so a
    /// session left open by an older build still gets closed. See ``DeviceIdentity``.
    ///
    /// Optional because CloudKit needs every attribute to be optional or defaulted.
    public var deviceID: String?

    @Relationship(inverse: \Station.sessions)
    public var station: Station?

    @Relationship(deleteRule: .nullify)
    public var captures: [Capture]? = []

    public init(
        startedAt: Date = .now,
        station: Station? = nil,
        deviceID: String? = DeviceIdentity.current
    ) {
        self.startedAt = startedAt
        self.lastActivityAt = startedAt
        self.station = station
        self.deviceID = deviceID
    }

    public var isOpen: Bool { endedAt == nil }

    /// Wall-clock length. Uses `lastActivityAt` for an open session so a session left
    /// open by a missed close does not report hours of listening that did not happen.
    public var duration: TimeInterval {
        (endedAt ?? lastActivityAt).timeIntervalSince(startedAt)
    }
}
