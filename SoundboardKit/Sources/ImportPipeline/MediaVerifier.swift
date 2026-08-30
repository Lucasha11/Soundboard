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
    /// how many image descriptors the file actually contains. This is what stops
    /// a small file from expanding into an enormous decode.
    private func verifyGIFStructure(_ data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 10 else { throw ImportFailureCode.unreadableFile }

        let width = Int(bytes[6]) | Int(bytes[7]) << 8
        let height = Int(bytes[8]) | Int(bytes[9]) << 8
        guard width > 0, height > 0 else { throw ImportFailureCode.unreadableFile }
        guard width <= caps.maxPixelDimension, height <= caps.maxPixelDimension else {
            throw ImportFailureCode.dimensionsTooLarge
        }

        // Image separator byte. Counting descriptors is a linear scan and gives
        // a hard upper bound on frames without decoding any of them.
        var frames = 0
        for byte in bytes where byte == 0x2C {
            frames += 1
            if frames > caps.maxFrameCount { throw ImportFailureCode.frameCountTooHigh }
        }
    }
}
