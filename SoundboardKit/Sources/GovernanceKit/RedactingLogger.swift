import Foundation

/// A value on its way to a log line, carrying its class with it.
public struct LogValue: Sendable {
    package let raw: String
    package let dataClass: DataClass

    public init(_ raw: String, _ dataClass: DataClass) {
        self.raw = raw
        self.dataClass = dataClass
    }

    /// Convenience for values that are safe by construction, such as enum codes.
    public static func operational(_ raw: String) -> LogValue { LogValue(raw, .c1) }
}

/// Destination for redacted lines. Real builds point this at OSLog.
public protocol LogSink: AnyObject {
    func write(_ line: String)
}

/// Redaction runs here, at the logging library boundary, so that it cannot be
/// forgotten at a call site (`DG-LOG-02`). A caller may hand this logger a C2
/// or C3 value; what reaches the sink is a class marker and nothing else.
///
/// `DG-LOG-01`: logs carry only C0 and C1 plus opaque identifiers. Upload
/// filenames are named explicitly in that rule, which is why the import
/// pipeline has no filename field to begin with.
public final class RedactingLogger {
    private let subsystem: String
    private let sink: LogSink

    public init(subsystem: String, sink: LogSink) {
        self.subsystem = subsystem
        self.sink = sink
    }

    public func log(_ event: String, _ fields: [String: LogValue] = [:]) {
        let rendered = fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(Self.redact($0.value))" }
            .joined(separator: " ")
        sink.write(rendered.isEmpty ? "[\(subsystem)] \(event)" : "[\(subsystem)] \(event) \(rendered)")
    }

    /// Non-loggable classes never reach the sink in any form, not even
    /// truncated or hashed. A hash of a small domain is still a lookup key.
    package static func redact(_ value: LogValue) -> String {
        guard value.dataClass.isLoggable else {
            return "<redacted:\(value.dataClass.rawValue)>"
        }
        return scrubFreeText(value.raw)
    }

    /// Second line of defence for values a caller mislabelled as C1. Catches the
    /// shapes that most often turn out to be personal: contact strings, file
    /// paths from a user's device, and network addresses.
    package static func scrubFreeText(_ raw: String) -> String {
        var out = raw
        for pattern in Self.sensitiveShapes {
            out = pattern.stringByReplacingMatches(
                in: out,
                range: NSRange(out.startIndex..., in: out),
                withTemplate: "<redacted:shape>"
            )
        }
        return out
    }

    private static let sensitiveShapes: [NSRegularExpression] = {
        let sources = [
            #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,   // contact string
            #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#,                       // v4 network address
            #"/(?:Users|var/mobile|private)/[^\s]+"#,              // device file path
        ]
        return sources.compactMap { try? NSRegularExpression(pattern: $0) }
    }()
}
