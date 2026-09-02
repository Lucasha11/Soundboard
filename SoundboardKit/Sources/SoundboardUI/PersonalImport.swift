import Foundation
import UniformTypeIdentifiers

/// What the file picker will let the user choose.
///
/// The picker is a convenience, not a control: the bytes are still sniffed at
/// the gate, which is what actually decides (`DG-SEC-04`). A user who renames a
/// zip to `.m4a` gets past the picker and is refused by the verifier. That is
/// the right division of labour - a picker filter is a hint, and a hint is
/// never a boundary.
enum PersonalImport {
    /// Mirrors `SourceContainer`'s audio-bearing cases.
    static let audioTypes: [UTType] = [.mp3, .mpeg4Audio, .wav, .aiff, .audio]

    /// And its visual ones. `.gif` first, since pairing a gif with a sound is
    /// the feature this exists for.
    static let visualTypes: [UTType] = [.gif, .png, .jpeg, .heic, .image]
}
