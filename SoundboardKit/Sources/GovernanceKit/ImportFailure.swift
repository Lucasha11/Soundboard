import Foundation

/// Why an import was refused.
///
/// This is a closed enum rather than a message string on purpose. The decoder's
/// own error text can echo attacker-controlled bytes from the source file, and
/// `DG-LOG-01` keeps that out of logs. The user sees a mapped, neutral string;
/// the log sees this code.
public enum ImportFailureCode: String, Error, Codable, Sendable, CaseIterable {
    case unsupportedContainer
    case unreadableFile
    case fileTooLarge
    case sourceTooLong
    case dimensionsTooLarge
    case frameCountTooHigh
    case noAudioTrack
    case noVideoTrack
    case decodeTimeout
    case decodeFailed
    case silentSelection
    case audioEncodeFailed
    case animationEncodeFailed
    case posterEncodeFailed
    case encodeFailed
    case storageFull

    /// C1 by construction: an enum case name carries nothing about the user.
    public var logValue: LogValue { .operational(rawValue) }

    /// What the user is told.
    ///
    /// Written out per case rather than derived from the case name, because
    /// these are the only strings in the import path a person ever reads and
    /// they should say what to do next. Deliberately no decoder text and no
    /// filename: the decoder's own message can echo bytes from the file, and
    /// `DG-LOG-01` names upload filenames as the thing to keep out of anything
    /// quotable - a failure a user photographs into a support ticket leaks the
    /// same way a log line does.
    public var userMessage: String {
        switch self {
        case .unsupportedContainer:
            return "That file type is not supported. Try an mp3, m4a or wav for sound, or a gif, png or jpeg for the picture."
        case .unreadableFile:
            return "That file could not be read. It may be damaged or incomplete."
        case .fileTooLarge:
            return "That file is too large to import."
        case .sourceTooLong:
            return "That recording is too long. Pick something shorter."
        case .dimensionsTooLarge:
            return "That picture is too large. Try one under 4096 pixels a side."
        case .frameCountTooHigh:
            return "That gif has too many frames to import."
        case .noAudioTrack:
            return "That file has no sound in it."
        case .noVideoTrack:
            return "That file has no picture in it."
        case .decodeTimeout:
            return "That file took too long to read and was stopped."
        case .decodeFailed, .encodeFailed, .audioEncodeFailed, .animationEncodeFailed, .posterEncodeFailed:
            return "That file could not be converted into a tile."
        case .silentSelection:
            return "That part of the sound is silent. Pick a different moment."
        case .storageFull:
            return "There is not enough space left to save this tile."
        }
    }
}
