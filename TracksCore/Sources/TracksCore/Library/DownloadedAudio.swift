import Foundation

/// Whether a downloaded file is the song, or a page the server sent in its place. A Subsonic
/// server answers a song it can't send with HTTP 200 and a small XML error, which would
/// otherwise be kept as a song that never plays.
public enum DownloadedAudio {
    /// How many bytes from the start of the file ``isAudio(mimeType:head:size:)`` wants.
    public static let headLength = 16
    /// An error page is a few hundred bytes; no song is this small.
    static let errorPageLimit: Int64 = 64 * 1024

    public static func isAudio(mimeType: String?, head: Data, size: Int64) -> Bool {
        let type = mimeType?.lowercased() ?? ""
        if type.hasPrefix("text/") || type.contains("xml") || type.contains("json") || type.contains("html") {
            return false
        }
        guard size < errorPageLimit else { return true }
        // No audio format starts with these: FLAC, ID3, MPEG frames, RIFF, Ogg and MP4 don't.
        let first = head.drop { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D || $0 == 0xEF || $0 == 0xBB || $0 == 0xBF }.first
        return first != UInt8(ascii: "<") && first != UInt8(ascii: "{") && size > 0
    }
}
