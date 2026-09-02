import Foundation
import GovernanceKit

/// The hostile-media fixture corpus required by `BACKEND_PLAN.md` Section 10.
///
/// **Synthetic only.** `DG-STOP-01/P9` bars production data from tests, and
/// nothing here is derived from a real file: every fixture is assembled byte by
/// byte below, so the corpus can be read and reasoned about rather than trusted.
///
/// Two properties matter and they are different. A fixture must be *rejected*,
/// which the verifier proves, and rejecting it must leave *nothing behind*,
/// which only the full pipeline can prove. `VerifierChecks` asserts the first
/// against `expectedAtGate`; `ImportPipelineChecks` drives every entry through
/// `SoundLibrary.importClip` and asserts the second.
enum HostileCorpus {
    struct Fixture {
        let name: String
        let bytes: Data
        /// The code the verification gate should raise, when the fixture is one
        /// the gate can settle from bytes alone. `nil` means the fixture is
        /// well-formed enough to sniff and must instead be refused deeper in,
        /// by the decoder - still with an `ImportFailureCode`, never a crash.
        let expectedAtGate: ImportFailureCode?
    }

    // MARK: - Builders

    /// A GIF header with the canvas size and frame count the caller asks for.
    /// Both fields are cheap for an attacker to lie about, which is exactly why
    /// the gate reads them before handing anything to a decoder.
    static func gif(width: Int, height: Int, frames: Int) -> Data {
        var bytes = Array("GIF89a".utf8)
        bytes += [UInt8(width & 0xFF), UInt8((width >> 8) & 0xFF)]
        bytes += [UInt8(height & 0xFF), UInt8((height >> 8) & 0xFF)]
        bytes += [0x00, 0x00]                       // packed fields, background
        bytes += [UInt8](repeating: 0x00, count: 8) // padding to a sane header length
        for _ in 0..<frames {
            bytes.append(0x2C)                      // image descriptor separator
            bytes += [UInt8](repeating: 0x00, count: 9)
        }
        bytes.append(0x3B)                          // trailer
        return Data(bytes)
    }

    /// Deterministic pseudo-random bytes. A real RNG would make a failure
    /// unreproducible, and a flaky corpus is worse than no corpus.
    static func noise(count: Int, seed: UInt64 = 0x5EED) -> Data {
        var state = seed
        var out = [UInt8]()
        out.reserveCapacity(count)
        for _ in 0..<count {
            // xorshift64: tiny, deterministic, and good enough to defeat sniffing.
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            out.append(UInt8(truncatingIfNeeded: state))
        }
        return Data(out)
    }

    private static func padded(_ prefix: [UInt8], to count: Int = 40) -> Data {
        Data(prefix + [UInt8](repeating: 0, count: max(0, count - prefix.count)))
    }

    // MARK: - Well-formed fixtures, for the sniffing checks

    static let png = padded([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    static let jpeg = padded([0xFF, 0xD8, 0xFF, 0xE0])
    static let wav = padded(Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WAVE".utf8))
    static let mp3 = padded(Array("ID3".utf8))
    static let heic = padded([0, 0, 0, 0] + Array("ftyp".utf8) + Array("heic".utf8))
    static let mp4 = padded([0, 0, 0, 0] + Array("ftyp".utf8) + Array("isom".utf8))
    static let m4a = padded([0, 0, 0, 0] + Array("ftyp".utf8) + Array("M4A ".utf8))

    /// A ZIP renamed to look like audio. The extension says one thing, the
    /// bytes say another, and the bytes are what the gate reads.
    static let disguisedArchive = padded(Array("PK\u{03}\u{04}".utf8))

    // MARK: - The corpus

    static let all: [Fixture] = [
        Fixture(name: "empty file", bytes: Data(), expectedAtGate: .unreadableFile),

        // Below the shortest prefix any container needs. Damaged, not
        // unsupported - the user can act on one message and not the other.
        Fixture(name: "three-byte truncated GIF header", bytes: Data([0x47, 0x49, 0x46]), expectedAtGate: .unreadableFile),
        Fixture(name: "one byte under the identifiable minimum", bytes: Data([UInt8](repeating: 0x47, count: 11)), expectedAtGate: .unreadableFile),

        // The two header fields that drive memory use, both lied about.
        Fixture(name: "GIF claiming a 20000x20000 canvas", bytes: gif(width: 20_000, height: 20_000, frames: 2), expectedAtGate: .dimensionsTooLarge),
        Fixture(name: "GIF claiming 900 frames", bytes: gif(width: 320, height: 320, frames: 900), expectedAtGate: .frameCountTooHigh),
        Fixture(name: "GIF with a zero-area canvas", bytes: gif(width: 0, height: 0, frames: 2), expectedAtGate: .unreadableFile),
        Fixture(name: "GIF with one dimension zero", bytes: gif(width: 320, height: 0, frames: 2), expectedAtGate: .unreadableFile),

        // A valid header cut off mid-descriptor: the decoder is invited to read
        // past the end of the buffer.
        Fixture(name: "GIF truncated mid image-descriptor", bytes: gif(width: 320, height: 320, frames: 6).prefix(28), expectedAtGate: nil),

        // Bytes that claim, by name, to be something they are not. The gate
        // reads content and never the extension or a claimed UTI.
        Fixture(name: "ZIP archive renamed to .m4a", bytes: disguisedArchive, expectedAtGate: .unsupportedContainer),
        Fixture(
            name: "ZIP bomb shape: tiny file declaring an enormous expansion",
            bytes: Data(Array("PK\u{03}\u{04}".utf8) + [0x14, 0x00, 0x00, 0x00, 0x08, 0x00] + [UInt8](repeating: 0xFF, count: 34)),
            expectedAtGate: .unsupportedContainer
        ),
        Fixture(name: "ELF executable renamed to media", bytes: padded([0x7F] + Array("ELF".utf8)), expectedAtGate: .unsupportedContainer),
        Fixture(name: "HTML error page saved as a clip", bytes: padded(Array("<!DOCTYPE html><html>".utf8)), expectedAtGate: .unsupportedContainer),

        Fixture(name: "deterministic noise with no magic number", bytes: noise(count: 4096), expectedAtGate: .unsupportedContainer),
        Fixture(name: "all zero bytes", bytes: Data(repeating: 0, count: 4096), expectedAtGate: .unsupportedContainer),

        // Audio with lying headers: the magic number is honest, everything
        // after it is not.
        Fixture(
            name: "WAV declaring a chunk size far past end of file",
            bytes: Data(Array("RIFF".utf8) + [0xFF, 0xFF, 0xFF, 0x7F] + Array("WAVE".utf8) + Array("fmt ".utf8) + [0xFF, 0xFF, 0xFF, 0x7F] + [UInt8](repeating: 0, count: 20)),
            expectedAtGate: nil
        ),
        Fixture(
            name: "MP3 frame sync followed by garbage",
            bytes: Data([0xFF, 0xFB] + [UInt8](noise(count: 38))),
            expectedAtGate: nil
        ),
        Fixture(name: "ID3 tag with no audio frames", bytes: padded(Array("ID3".utf8) + [0x04, 0x00, 0x00]), expectedAtGate: nil),

        // Containers that sniff cleanly and hold nothing. These get past the
        // gate by design and must be refused by the decoder, with a code.
        Fixture(name: "MP4 brand with no tracks", bytes: mp4, expectedAtGate: nil),
        Fixture(name: "M4A brand with no tracks", bytes: m4a, expectedAtGate: nil),
        Fixture(name: "HEIC brand with no image payload", bytes: heic, expectedAtGate: nil),
        Fixture(name: "PNG signature with no chunks", bytes: png, expectedAtGate: nil),
        Fixture(name: "JPEG SOI with no scan", bytes: jpeg, expectedAtGate: nil),
    ]
}
