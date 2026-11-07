import Foundation

/// What a FLAC file says about itself: its stream (length, sample rate, bit depth), its tags,
/// and its cover.
///
/// Read straight from the metadata blocks at the head of the file, which is all a FLAC's tags
/// are: STREAMINFO, then Vorbis comments and pictures, each behind a four-byte header. An ID3
/// tag some encoders put in front is stepped over.
public struct FLACMetadata: Sendable, Equatable {
    public var sampleRate: Int?
    public var channels: Int?
    public var bitDepth: Int?
    public var duration: TimeInterval?
    /// Vorbis comments by upper-cased name. A name given more than once keeps every value.
    public var comments: [String: [String]] = [:]
    /// The front cover where there is one, otherwise the first picture.
    public var picture: Picture?

    public struct Picture: Sendable, Equatable {
        public var mimeType: String
        public var data: Data
    }

    public enum ReadError: Error, Equatable {
        /// Not a FLAC file: no "fLaC" where the stream should start.
        case notFLAC
        /// The file ends in the middle of a block.
        case truncated
    }

    /// Reads a file's metadata, asking for the bytes it needs and no more.
    ///
    /// - Parameter read: the bytes at an offset, as many as asked for or fewer at the end.
    public static func read(_ read: (_ offset: Int, _ count: Int) throws -> Data) throws -> FLACMetadata {
        var offset = 0
        var head = try read(0, 10)
        // An ID3v2 tag: "ID3", version, flags, then a synchsafe size.
        if head.count >= 10, head.starts(with: [0x49, 0x44, 0x33]) {
            let bytes = [UInt8](head)
            let size = (Int(bytes[6]) << 21) | (Int(bytes[7]) << 14) | (Int(bytes[8]) << 7) | Int(bytes[9])
            let hasFooter = bytes[5] & 0x10 != 0
            offset = 10 + size + (hasFooter ? 10 : 0)
            head = try read(offset, 4)
        }
        guard head.count >= 4, head.prefix(4).elementsEqual([0x66, 0x4C, 0x61, 0x43]) else { throw ReadError.notFLAC }
        offset += 4

        var metadata = FLACMetadata()
        var isLast = false
        while !isLast {
            let header = [UInt8](try read(offset, 4))
            guard header.count == 4 else { throw ReadError.truncated }
            isLast = header[0] & 0x80 != 0
            let type = header[0] & 0x7F
            let length = (Int(header[1]) << 16) | (Int(header[2]) << 8) | Int(header[3])
            offset += 4
            switch type {
            case 0, 4, 6:
                let body = try read(offset, length)
                guard body.count == length else { throw ReadError.truncated }
                switch type {
                case 0: metadata.readStreamInfo([UInt8](body))
                case 4: metadata.readComments([UInt8](body))
                default: metadata.readPicture([UInt8](body))
                }
            default:
                // Padding, seek tables, cue sheets: nothing to read.
                break
            }
            offset += length
            // 127 is invalid; a file that says so is damaged past this point.
            if type == 127 { break }
        }
        return metadata
    }

    /// Reads from data already in memory.
    public static func read(_ data: Data) throws -> FLACMetadata {
        try read { offset, count in
            guard offset < data.count else { return Data() }
            let start = data.index(data.startIndex, offsetBy: offset)
            let end = data.index(start, offsetBy: min(count, data.count - offset))
            return data[start..<end]
        }
    }

    // MARK: - Blocks

    private mutating func readStreamInfo(_ bytes: [UInt8]) {
        guard bytes.count >= 18 else { return }
        let rate = (Int(bytes[10]) << 12) | (Int(bytes[11]) << 4) | (Int(bytes[12]) >> 4)
        let channels = (Int(bytes[12]) >> 1 & 0x07) + 1
        let bits = ((Int(bytes[12]) & 0x01) << 4 | Int(bytes[13]) >> 4) + 1
        let samples = (Int(bytes[13]) & 0x0F) << 32 | Int(bytes[14]) << 24 | Int(bytes[15]) << 16 | Int(bytes[16]) << 8 | Int(bytes[17])
        sampleRate = rate > 0 ? rate : nil
        self.channels = channels
        bitDepth = bits
        duration = rate > 0 && samples > 0 ? Double(samples) / Double(rate) : nil
    }

    private mutating func readComments(_ bytes: [UInt8]) {
        var reader = LittleEndianReader(bytes: bytes)
        guard let vendorLength = reader.uint32(), reader.skip(Int(vendorLength)), let count = reader.uint32() else { return }
        for _ in 0..<count {
            guard let length = reader.uint32(), let field = reader.string(Int(length)) else { return }
            guard let equals = field.firstIndex(of: "=") else { continue }
            let name = field[..<equals].uppercased()
            let value = String(field[field.index(after: equals)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            comments[name, default: []].append(value)
        }
    }

    private mutating func readPicture(_ bytes: [UInt8]) {
        var reader = BigEndianReader(bytes: bytes)
        guard let type = reader.uint32(),
              let mimeLength = reader.uint32(), let mime = reader.string(Int(mimeLength)),
              let descriptionLength = reader.uint32(), reader.skip(Int(descriptionLength)),
              reader.skip(16),
              let dataLength = reader.uint32(), let data = reader.take(Int(dataLength))
        else { return }
        // The front cover (type 3) wins; otherwise the first picture there is.
        guard picture == nil || type == 3 else { return }
        picture = Picture(mimeType: mime, data: Data(data))
    }

    // MARK: - Tags

    public func first(_ name: String) -> String? { comments[name]?.first }

    public var title: String? { first("TITLE") }
    /// Every artist named, together: "Artist A, Artist B".
    public var artist: String? { comments["ARTIST"].map { $0.joined(separator: ", ") } }
    public var albumArtist: String? { first("ALBUMARTIST") ?? first("ALBUM ARTIST") ?? first("ALBUM_ARTIST") }
    public var album: String? { first("ALBUM") }
    public var genre: String? { first("GENRE") }
    public var trackNumber: Int? { Self.leadingNumber(first("TRACKNUMBER")) }
    public var discNumber: Int? { Self.leadingNumber(first("DISCNUMBER")) }
    /// The year of "2019", "2019-05-01" or "05/01/2019".
    public var year: Int? {
        guard let date = first("DATE") ?? first("YEAR") ?? first("ORIGINALDATE") else { return nil }
        let runs: [Substring] = date.split(whereSeparator: { !$0.isNumber })
        return runs.first { $0.count == 4 }.flatMap { Int(String($0)) }
    }

    /// "3" of "3" or "3/12".
    static func leadingNumber(_ text: String?) -> Int? {
        guard let text else { return nil }
        return Int(text.prefix { $0.isNumber })
    }

    public var format: AudioFormat {
        AudioFormat(codec: "FLAC", sampleRate: sampleRate, bitDepth: bitDepth)
    }
}

private struct LittleEndianReader {
    let bytes: [UInt8]
    var position = 0

    mutating func uint32() -> UInt32? {
        guard position + 4 <= bytes.count else { return nil }
        defer { position += 4 }
        return UInt32(bytes[position]) | UInt32(bytes[position + 1]) << 8 | UInt32(bytes[position + 2]) << 16 | UInt32(bytes[position + 3]) << 24
    }

    mutating func skip(_ count: Int) -> Bool {
        guard count >= 0, position + count <= bytes.count else { return false }
        position += count
        return true
    }

    mutating func string(_ count: Int) -> String? {
        guard count >= 0, position + count <= bytes.count else { return nil }
        defer { position += count }
        return String(decoding: bytes[position..<position + count], as: UTF8.self)
    }
}

private struct BigEndianReader {
    let bytes: [UInt8]
    var position = 0

    mutating func uint32() -> UInt32? {
        guard position + 4 <= bytes.count else { return nil }
        defer { position += 4 }
        return UInt32(bytes[position]) << 24 | UInt32(bytes[position + 1]) << 16 | UInt32(bytes[position + 2]) << 8 | UInt32(bytes[position + 3])
    }

    mutating func skip(_ count: Int) -> Bool {
        guard count >= 0, position + count <= bytes.count else { return false }
        position += count
        return true
    }

    mutating func string(_ count: Int) -> String? {
        take(count).map { String(decoding: $0, as: UTF8.self) }
    }

    mutating func take(_ count: Int) -> ArraySlice<UInt8>? {
        guard count >= 0, position + count <= bytes.count else { return nil }
        defer { position += count }
        return bytes[position..<position + count]
    }
}
