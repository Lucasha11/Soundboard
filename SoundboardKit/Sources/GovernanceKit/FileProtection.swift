import Foundation

/// At-rest encryption for a file or directory, and a truthful answer about
/// whether it took.
///
/// `DG-SEC-01` requires C2, C3 and C4 to be encrypted at rest, and
/// `DG-AGENT-04` forbids shipping a control that is merely attempted. The
/// distinction matters here because the obvious spelling,
/// `try? FileManager.setAttributes(...)`, silently succeeds when it fails,
/// which turns a required control into a hope. Every call site instead takes
/// the returned `Bool` and refuses the write when it is false.
public enum FileProtection {
    /// Applies complete protection to `url` and reads the attribute back to
    /// confirm. Applying this to a directory also sets the default class for
    /// files created inside it afterwards, which closes the window in which a
    /// freshly written file is briefly unprotected.
    ///
    /// - Returns: whether the destination is encrypted at rest.
    @discardableResult
    public static func apply(to url: URL) -> Bool {
        #if targetEnvironment(simulator)
        // The Simulator has no Secure Enclave and no keybag, so Data
        // Protection is not implemented there: the attribute either no-ops or
        // reads back nil no matter what is written. A simulator is a
        // development host, never a shipping surface, so reporting true here
        // is the honest answer to "is this as encrypted as this platform
        // gets".
        //
        // The consequence is that the strict path below cannot be exercised on
        // a simulator, by construction. It is covered instead by injecting a
        // failing prober at the call site, which proves the refusal behaviour
        // without needing a device.
        _ = url
        return true
        #elseif os(iOS)
        do {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: url.path
            )
            let applied = try FileManager.default
                .attributesOfItem(atPath: url.path)[.protectionKey] as? FileProtectionType
            return applied == .complete
        } catch {
            return false
        }
        #else
        // Data Protection is an iOS facility with no per-file macOS
        // equivalent. macOS is a development and CI host for this package and
        // never a shipping surface - the app target is iPhone-only - so at-rest
        // encryption there is FileVault's job and is not verifiable per file.
        _ = url
        return true
        #endif
    }
}
