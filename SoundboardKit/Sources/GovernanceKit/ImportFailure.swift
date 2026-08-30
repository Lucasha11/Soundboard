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
}
