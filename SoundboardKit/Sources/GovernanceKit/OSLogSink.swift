import Foundation
import os

/// Sends redacted lines to the system log.
///
/// `RedactingLogger` and its `LogSink` protocol existed, were covered, and had
/// no implementation the app could use - so nothing in the shipping app logged
/// anything, and `DG-LOG-02`'s "redaction filter at the logging library
/// boundary" was a boundary with nothing flowing through it. A control that
/// nothing uses is not a control.
///
/// Everything reaching `write` has already been through the redactor, so the
/// interpolation is deliberately marked public: the privacy work happened
/// upstream, and marking it private here would only hide already-safe text
/// from the developer reading it.
public final class OSLogSink: LogSink {
    private let logger: os.Logger

    public init(subsystem: String = "com.soundboard.app", category: String) {
        self.logger = os.Logger(subsystem: subsystem, category: category)
    }

    public func write(_ line: String) {
        logger.log("\(line, privacy: .public)")
    }
}
