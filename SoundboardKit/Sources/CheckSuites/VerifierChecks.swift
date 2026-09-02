import Foundation
import GovernanceKit
import ImportPipeline

enum VerifierChecks {
    static func run() {
        let verifier = MediaVerifier()

        Check.suite("MediaVerifier - sniffing by content, never by extension") {
            Check.expectEqual(MediaVerifier.sniff(HostileCorpus.gif(width: 320, height: 320, frames: 4)), .gif, "GIF89a detected")
            Check.expectEqual(MediaVerifier.sniff(HostileCorpus.png), .png, "PNG detected")
            Check.expectEqual(MediaVerifier.sniff(HostileCorpus.jpeg), .jpeg, "JPEG detected")
            Check.expectEqual(MediaVerifier.sniff(HostileCorpus.wav), .wav, "WAV detected")
            Check.expectEqual(MediaVerifier.sniff(HostileCorpus.mp3), .mp3, "MP3 with an ID3 tag detected")
            Check.expectEqual(MediaVerifier.sniff(HostileCorpus.heic), .heic, "HEIC brand detected")
            Check.expectEqual(MediaVerifier.sniff(HostileCorpus.mp4), .mp4, "MP4 brand detected")
            Check.expect(MediaVerifier.sniff(HostileCorpus.disguisedArchive) == nil, "an archive renamed to .m4a is not audio")
        }

        Check.suite("MediaVerifier - hostile input gate, DG-SEC-04") {
            Check.expectThrows(ImportFailureCode.unsupportedContainer, "an unknown container is refused") {
                _ = try verifier.verify(data: HostileCorpus.disguisedArchive)
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
                _ = try MediaVerifier(caps: tinyCaps).verify(data: HostileCorpus.gif(width: 320, height: 320, frames: 40))
            }

            // The two header fields that drive memory use are checked before the
            // decoder ever sees the file. This is what stops a small file from
            // expanding into an enormous decode.
            Check.expectThrows(ImportFailureCode.dimensionsTooLarge, "an absurd canvas size is refused") {
                _ = try verifier.verify(data: HostileCorpus.gif(width: 20000, height: 20000, frames: 2))
            }
            Check.expectThrows(ImportFailureCode.frameCountTooHigh, "an absurd frame count is refused") {
                _ = try verifier.verify(data: HostileCorpus.gif(width: 320, height: 320, frames: 900))
            }
            Check.expectThrows(ImportFailureCode.unreadableFile, "a zero-dimension canvas is refused") {
                _ = try verifier.verify(data: HostileCorpus.gif(width: 0, height: 0, frames: 2))
            }

            let ok = try verifier.verify(data: HostileCorpus.gif(width: 480, height: 852, frames: 30))
            Check.expectEqual(ok.container, .gif, "a well-formed vertical gif passes the gate")

            // Regression, found by importing a real gif. 0x2C is the image
            // separator and also a comma, so it is everywhere inside LZW pixel
            // data. Counting occurrences made an ordinary 12-frame gif scan as
            // 1146 frames and be refused - the gate would have rejected most
            // real gifs a user tried to import, while a malicious file could
            // still hide its true frame count under the cap.
            let realistic = try verifier.verify(data: HostileCorpus.gifWithCommasInPixelData)
            Check.expectEqual(
                realistic.container, .gif,
                "a 12-frame gif whose pixel data is full of 0x2C bytes still imports"
            )
        }

        // The corpus is the checked-in record of what hostile input looks
        // like, so every entry that the gate can settle from bytes alone is
        // asserted here rather than in prose.
        Check.suite("MediaVerifier - the whole hostile corpus, DG-SEC-04") {
            for fixture in HostileCorpus.all {
                guard let expected = fixture.expectedAtGate else { continue }
                Check.expectThrows(expected, "\(fixture.name): refused at the gate as \(expected.rawValue)") {
                    _ = try verifier.verify(data: fixture.bytes)
                }
            }

            // The corpus must keep earning its place: an entry that no longer
            // describes a distinct shape is worse than no entry, because it
            // reads as coverage.
            Check.expectEqual(
                Set(HostileCorpus.all.map(\.name)).count, HostileCorpus.all.count,
                "every fixture is distinctly named"
            )
            Check.expect(HostileCorpus.all.count >= 20, "the corpus covers the shapes 4.1 names")
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
