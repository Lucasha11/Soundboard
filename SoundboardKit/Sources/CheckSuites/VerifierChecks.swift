import Foundation
import GovernanceKit
import ImportPipeline

/// Synthetic fixtures only. DG-STOP-01/P9 bars production data from tests, and
/// these are the malformed shapes a real import gate has to survive.
private enum Fixture {
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

    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + [UInt8](repeating: 0, count: 24))
    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: 0, count: 28))
    static let wav = Data(Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WAVE".utf8) + [UInt8](repeating: 0, count: 20))
    static let mp3 = Data(Array("ID3".utf8) + [UInt8](repeating: 0, count: 29))
    static let heic = Data([0, 0, 0, 0] + Array("ftyp".utf8) + Array("heic".utf8) + [UInt8](repeating: 0, count: 20))
    static let mp4 = Data([0, 0, 0, 0] + Array("ftyp".utf8) + Array("isom".utf8) + [UInt8](repeating: 0, count: 20))

    /// A ZIP renamed to look like audio. The extension says one thing, the bytes
    /// say another, and the bytes are what the gate reads.
    static let disguisedArchive = Data(Array("PK\u{03}\u{04}".utf8) + [UInt8](repeating: 0, count: 28))
}

enum VerifierChecks {
    static func run() {
        let verifier = MediaVerifier()

        Check.suite("MediaVerifier - sniffing by content, never by extension") {
            Check.expectEqual(MediaVerifier.sniff(Fixture.gif(width: 320, height: 320, frames: 4)), .gif, "GIF89a detected")
            Check.expectEqual(MediaVerifier.sniff(Fixture.png), .png, "PNG detected")
            Check.expectEqual(MediaVerifier.sniff(Fixture.jpeg), .jpeg, "JPEG detected")
            Check.expectEqual(MediaVerifier.sniff(Fixture.wav), .wav, "WAV detected")
            Check.expectEqual(MediaVerifier.sniff(Fixture.mp3), .mp3, "MP3 with an ID3 tag detected")
            Check.expectEqual(MediaVerifier.sniff(Fixture.heic), .heic, "HEIC brand detected")
            Check.expectEqual(MediaVerifier.sniff(Fixture.mp4), .mp4, "MP4 brand detected")
            Check.expect(MediaVerifier.sniff(Fixture.disguisedArchive) == nil, "an archive renamed to .m4a is not audio")
        }

        Check.suite("MediaVerifier - hostile input gate, DG-SEC-04") {
            Check.expectThrows(ImportFailureCode.unsupportedContainer, "an unknown container is refused") {
                _ = try verifier.verify(data: Fixture.disguisedArchive)
            }
            Check.expectThrows(ImportFailureCode.unreadableFile, "an empty file is refused") {
                _ = try verifier.verify(data: Data())
            }
            // A truncated file reports as damaged, not as an unsupported format.
            // The user can act on the first message and cannot act on the second.
            Check.expectThrows(ImportFailureCode.unreadableFile, "a truncated header reads as damaged, not unsupported") {
                _ = try verifier.verify(data: Data([0x47, 0x49, 0x46]))
            }

            let tinyCaps = ImportCaps(
                maxSourceBytes: 64, maxSourceDuration: 600, maxPixelDimension: 4096,
                maxFrameCount: 600, decodeTimeout: 10, maxClipDuration: 2
            )
            Check.expectThrows(ImportFailureCode.fileTooLarge, "an oversized file is refused before any decode") {
                _ = try MediaVerifier(caps: tinyCaps).verify(data: Fixture.gif(width: 320, height: 320, frames: 40))
            }

            // The two header fields that drive memory use are checked before the
            // decoder ever sees the file. This is what stops a small file from
            // expanding into an enormous decode.
            Check.expectThrows(ImportFailureCode.dimensionsTooLarge, "an absurd canvas size is refused") {
                _ = try verifier.verify(data: Fixture.gif(width: 20000, height: 20000, frames: 2))
            }
            Check.expectThrows(ImportFailureCode.frameCountTooHigh, "an absurd frame count is refused") {
                _ = try verifier.verify(data: Fixture.gif(width: 320, height: 320, frames: 900))
            }
            Check.expectThrows(ImportFailureCode.unreadableFile, "a zero-dimension canvas is refused") {
                _ = try verifier.verify(data: Fixture.gif(width: 0, height: 0, frames: 2))
            }

            let ok = try verifier.verify(data: Fixture.gif(width: 480, height: 852, frames: 30))
            Check.expectEqual(ok.container, .gif, "a well-formed vertical gif passes the gate")
        }

        Check.suite("ImportFailureCode - DG-LOG-01") {
            // Every rejection path carries an enum, so no decoder text and no
            // source filename can reach a log line through an error message.
            for code in ImportFailureCode.allCases {
                Check.expect(code.logValue.raw == code.rawValue, "\(code.rawValue) logs as an opaque code")
            }
        }
    }
}
