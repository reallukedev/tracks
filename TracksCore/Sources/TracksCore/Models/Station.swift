import Foundation
import SwiftData

/// A radio station, identified by catalog ID where we have one and by name where we don't.
///
/// The Mac only ever learns a station's name, so `catalogID` stays nil there until an
/// iPhone capture of the same station fills it in.
@Model
public final class Station {
    public var name: String = ""
    public var catalogID: String?
    public var artworkURL: String?
    public var firstSeenAt: Date = Date.distantPast
    public var lastSeenAt: Date = Date.distantPast

    /// Nullify, not cascade. Stations are merged across devices (see
    /// ``TracksStore/mergeDuplicateStations()``), and the device doing the merge can only move
    /// the sessions it already has. A session another device recorded against the duplicate
    /// hasn't synced there yet, so a cascade would delete that listening history on every
    /// device once the station's deletion arrived. Nullified, the session loses its station
    /// but keeps its plays, and an open one is named again on its next observation.
    ///
    /// The delete rule isn't part of the store's version hash, so changing it needs no
    /// migration.
    @Relationship(deleteRule: .nullify)
    public var sessions: [Session]? = []

    public init(
        name: String,
        catalogID: String? = nil,
        artworkURL: String? = nil,
        firstSeenAt: Date = .now
    ) {
        self.name = name
        self.catalogID = catalogID
        self.artworkURL = artworkURL
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = firstSeenAt
    }
}
