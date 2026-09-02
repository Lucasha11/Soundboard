import Foundation
import GovernanceKit

/// The verification gate. Runs before any real decode.
///
/// Everything here works on bytes the caller already holds, so a rejection
/// costs no decoder time and gives a malformed file no opportunity to run a
/// parser. Rejections carry an enum code, never decoder text (`DG-LOG-01`).
public struct MediaVerifier {
    private let caps: ImportCaps

    public init(caps: ImportCaps = .standard) {
        self.caps = caps
    }

    public struct Verified: Sendable {
        public let container: SourceContainer
        public let byteCount: Int
    }

    /// Shortest prefix any supported container needs to be identifiable.
    /// Below this the file is damaged rather than unsupported, and the two
    /// deserve different messages: one is worth re-exporting, the other is not.
    static let minimumIdentifiableBytes = 12

    public func verify(data: Data) throws -> Verified {
        guard data.count > 0 else { throw ImportFailureCode.unreadableFile }
        guard data.count <= caps.maxSourceBytes else { throw ImportFailureCode.fileTooLarge }
        guard data.count >= Self.minimumIdentifiableBytes else { throw ImportFailureCode.unreadableFile }
        guard let container = Self.sniff(data) else { throw ImportFailureCode.unsupportedContainer }

        if container == .gif {
            try verifyGIFStructure(data)
        }
        return Verified(container: container, byteCount: data.count)
    }

    public func verify(fileAt url: URL) throws -> Verified {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else { throw ImportFailureCode.unreadableFile }
        guard size <= caps.maxSourceBytes else { throw ImportFailureCode.fileTooLarge }
        // Only the header is needed to sniff, so a large file is not read whole
        // just to be rejected.
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ImportFailureCode.unreadableFile
        }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 64)) ?? Data()
        guard head.count >= Self.minimumIdentifiableBytes else { throw ImportFailureCode.unreadableFile }
        guard let container = Self.sniff(head) else { throw ImportFailureCode.unsupportedContainer }
        return Verified(container: container, byteCount: size)
    }

    // MARK: - Sniffing

    /// Magic-number detection. The extension is not consulted anywhere.
    package static func sniff(_ data: Data) -> SourceContainer? {
        let bytes = [UInt8](data.prefix(32))
        guard bytes.count >= 12 else { return nil }

        func matches(_ signature: [UInt8], at offset: Int) -> Bool {
            guard bytes.count >= offset + signature.count else { return false }
            return Array(bytes[offset..<(offset + signature.count)]) == signature
        }

        if matches(Array("GIF87a".utf8), at: 0) || matches(Array("GIF89a".utf8), at: 0) { return .gif }
        if matches([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], at: 0) { return .png }
        if matches([0xFF, 0xD8, 0xFF], at: 0) { return .jpeg }
        if matches(Array("RIFF".utf8), at: 0) && matches(Array("WAVE".utf8), at: 8) { return .wav }
        if matches(Array("FORM".utf8), at: 0) && (matches(Array("AIFF".utf8), at: 8) || matches(Array("AIFC".utf8), at: 8)) { return .aiff }
        if matches(Array("caff".utf8), at: 0) { return .caf }
        if matches([0x49, 0x44, 0x33], at: 0) { return .mp3 }              // ID3 tag
        if bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0 { return .mp3 }   // bare MPEG frame sync

        if matches(Array("ftyp".utf8), at: 4) {
            let brand = String(bytes: bytes[8..<12], encoding: .ascii) ?? ""
            switch brand {
            case "M4A ", "M4B ": return .m4a
            case "qt  ": return .quickTime
            case "heic", "heix", "hevc", "mif1", "msf1": return .heic
            default: return .mp4
            }
        }
        return nil
    }

    /// A GIF header is cheap to lie about, so the two fields that drive memory
    /// use are checked before the decoder is handed the file: canvas size and
    /// how many frames the file actually contains. This is what stops a small
    /// file from expanding into an enormous decode.
    ///
    /// The frame count is a real block walk, not a scan for the `0x2C`
    /// separator byte. Counting bytes was the obvious implementation and it is
    /// badly wrong: `0x2C` is a comma, and it occurs constantly inside LZW
    /// pixel data. An ordinary 12-frame 220x294 gif scans as 1146 "frames" and
    /// is refused as hostile - which would have rejected most real gifs a user
    /// tried to import, while a genuinely malicious file could still hide its
    /// frame count below the cap. Walking the block structure counts frames,
    /// and only frames.
    private func verifyGIFStructure(_ data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 13 else { throw ImportFailureCode.unreadableFile }

        let width = Int(bytes[6]) | Int(bytes[7]) << 8
        let height = Int(bytes[8]) | Int(bytes[9]) << 8
        guard width > 0, height > 0 else { throw ImportFailureCode.unreadableFile }
        guard width <= caps.maxPixelDimension, height <= caps.maxPixelDimension else {
            throw ImportFailureCode.dimensionsTooLarge
        }

        var cursor = 13
        // Global colour table, if the packed field says one is present.
        if bytes[10] & 0x80 != 0 {
            cursor += 3 * (1 << ((Int(bytes[10]) & 0x07) + 1))
        }

        var frames = 0
        // Every read below is bounds-checked and the cursor only moves
        // forward, so a truncated or malformed file ends the walk rather than
        // reading past the buffer or spinning (`DG-SEC-04`).
        walk: while cursor < bytes.count {
            switch bytes[cursor] {
            case 0x3B:                      // trailer
                break walk
            case 0x21:                      // extension: skip its sub-blocks
                cursor += 2
                cursor = try Self.skipSubBlocks(bytes, from: cursor)
            case 0x2C:                      // image descriptor: one real frame
                frames += 1
                if frames > caps.maxFrameCount { throw ImportFailureCode.frameCountTooHigh }
                cursor += 9
                guard cursor < bytes.count else { throw ImportFailureCode.unreadableFile }
                let packed = bytes[cursor]
                cursor += 1
                if packed & 0x80 != 0 {     // local colour table
                    cursor += 3 * (1 << ((Int(packed) & 0x07) + 1))
                }
                cursor += 1                 // LZW minimum code size
                cursor = try Self.skipSubBlocks(bytes, from: cursor)
            default:
                // Not a block boundary: the file is damaged rather than
                // oversized, and the two deserve different answers.
                throw ImportFailureCode.unreadableFile
            }
        }
    }

    /// Walks a GIF sub-block chain and returns the index just past its
    /// terminator. Bounds-checked, and every step advances.
    private static func skipSubBlocks(_ bytes: [UInt8], from start: Int) throws -> Int {
        var cursor = start
        while true {
            guard cursor < bytes.count else { throw ImportFailureCode.unreadableFile }
            let length = Int(bytes[cursor])
            if length == 0 { return cursor + 1 }
            cursor += length + 1
        }
    }
}
