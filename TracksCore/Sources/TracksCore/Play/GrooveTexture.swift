import Foundation

/// The preview's own sound, band by band, kept small enough to store with a ``Groove`` and
/// replayed in time with the song: every hit, fill, held chord and quiet moment where the
/// preview had them, so a busy track looks busy and a ballad swells as it really does.
///
/// It's cut into chunks, a bar each when the song has a beat, so a chunk replays on the
/// song's own bars, and two seconds each when it doesn't. Where the preview sits in the song
/// is known (see ``Groove/songOffset``), its stretch of the song replays exactly, and the rest
/// on the same bars. The chunks play forward, then back, each always forward inside, so a hit
/// never plays backwards.
public nonisolated struct GrooveTexture: Codable, Equatable, Sendable {
    /// Frames a chunk: a thirty-second note each in a bar of four.
    public static let framesPerChunk = 32
    /// A chunk's length, for a song with no beat to keep.
    public static let freeChunk = 2.0

    /// Seconds a chunk lasts: a bar at the song's tempo, or ``freeChunk``.
    public var chunkSeconds: Double
    public var bandCount: Int
    /// Each frame's bands, 0 to 255, frame after frame.
    public var levels: Data
    /// Seconds into the preview where the first chunk starts, on a downbeat when there's a beat.
    public var start: Double

    public init(chunkSeconds: Double, bandCount: Int, levels: Data, start: Double = 0) {
        self.chunkSeconds = chunkSeconds
        self.bandCount = bandCount
        self.levels = levels
        self.start = start
    }

    public var chunkCount: Int {
        bandCount > 0 ? levels.count / (bandCount * Self.framesPerChunk) : 0
    }

    /// Whether there's enough to replay: two chunks at least, so it can turn back.
    public var isPlayable: Bool {
        chunkCount >= 2 && chunkSeconds.isFinite && chunkSeconds > 0
    }

    /// The bands, 0 to 1, `position` seconds into the song, eased from one frame to the next.
    /// `origin` is where the first chunk falls in the song, when that's known; otherwise the
    /// bars count from the song's start.
    public func levels(at position: Double, origin: Double? = nil) -> [Float] {
        guard isPlayable else { return [] }
        let position = min(max(-1_000_000, position.isFinite ? position : 0), 1_000_000)
        let place = (position - (origin ?? 0)) / chunkSeconds
        let chunk = Int(place.rounded(.down))
        let through = (place - Double(chunk)) * Double(Self.framesPerChunk)
        let frame = min(Self.framesPerChunk - 1, Int(through))
        let blend = Float(min(1, max(0, through - Double(frame))))
        // Inside the preview's own stretch, exactly what it played there.
        let mapped = origin != nil && (0..<chunkCount).contains(chunk) ? chunk : Self.chunk(chunk, of: chunkCount)
        let here = (mapped * Self.framesPerChunk + frame) * bandCount
        // The last frame of a chunk eases toward the first of the one that plays next.
        let next: Int
        if frame + 1 < Self.framesPerChunk {
            next = here + bandCount
        } else {
            let following = origin != nil && (0..<chunkCount).contains(chunk + 1) ? chunk + 1 : Self.chunk(chunk + 1, of: chunkCount)
            next = following * Self.framesPerChunk * bandCount
        }
        return levels.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            (0..<bandCount).map { band in
                let a = Float(bytes[here + band]), b = Float(bytes[next + band])
                return (a + (b - a) * blend) / 255
            }
        }
    }

    /// Where each band's sound usually sits, low and high, 0 to 1: its quietest tenth and its
    /// loudest few moments. A replay spread across this range uses the full height whether the
    /// song is a crowded, loud master or a soft piano, so every genre moves as much as it
    /// changes. A band that hardly changes keeps a range wide enough not to magnify noise, about its middle.
    public func bandRange() -> (floor: [Float], ceiling: [Float]) {
        let frames = chunkCount * Self.framesPerChunk
        guard frames > 0 else { return ([], []) }
        var floor = [Float](repeating: 0, count: bandCount), ceiling = [Float](repeating: 1, count: bandCount)
        levels.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for band in 0..<bandCount {
                let values = (0..<frames).map { Float(bytes[$0 * bandCount + band]) / 255 }.sorted()
                let low = values[frames / 10], high = values[min(frames - 1, frames * 97 / 100)]
                // Widened about its middle, so a steady band sits mid-way rather than at the top.
                let span = max(0.2, high - low)
                floor[band] = max(0, (low + high - span) / 2)
                ceiling[band] = floor[band] + span
            }
        }
        return (floor, ceiling)
    }

    /// The preview's chunk for the song's `chunk`: forward, then back, then forward again,
    /// before the first as after the last.
    static func chunk(_ chunk: Int, of count: Int) -> Int {
        guard count > 1 else { return 0 }
        let cycle = 2 * (count - 1)
        let place = ((chunk % cycle) + cycle) % cycle
        return place < count ? place : cycle - place
    }
}
