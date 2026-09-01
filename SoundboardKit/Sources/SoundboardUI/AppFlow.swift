import Foundation
import GovernanceKit

/// Owns startup: build the object graph, or show why it could not be built.
///
/// Under `DATA_GOVERNANCE.md` v2.0 there is no age gate and no Restricted Mode
/// (`DG-USER-02`, relaxed), and the app carries a 12+ rating rather than
/// gating entry on a birthdate (`DG-USER-01`). So nothing stands between
/// launch and the board, and this type is correspondingly thin.
///
/// What v2.0 does keep strict is `DG-USER-04`: no tracking identifier read,
/// and no SDK that reads one initialised, before the ATT prompt resolves. That
/// is not a startup phase - it is a standing constraint enforced at the point
/// of use by `IdentifierVault`, over the process-wide `TrackingGate`. The gate
/// stays `.notDetermined` for now, which refuses every read, and that is the
/// correct state while no shipped feature consumes a tracking identifier.
@MainActor
public final class AppFlow: ObservableObject {
    public enum Phase {
        case ready(SoundboardComposition)
        case startupFailure(String)
    }

    @Published public private(set) var phase: Phase

    /// UI tests assert on-screen state and have no interest in audio. Real
    /// launches never pass this, so the shipping path always warms the engine.
    static let silentAudioLaunchArgument = "--uitest-silent-audio"

    /// - Parameter rootResult: `SoundboardComposition.defaultRoot()`, captured
    ///   by the caller so a container failure surfaces as a visible failure
    ///   screen instead of a board that silently does nothing.
    public init(rootResult: Result<URL, Error>) {
        switch rootResult {
        case let .failure(error):
            self.phase = .startupFailure(Self.safeDescription(of: error))
        case let .success(root):
            self.phase = Self.buildPhase(root: root)
        }
    }

    private static func buildPhase(root: URL) -> Phase {
        do {
            let composition = try SoundboardComposition(
                root: root,
                warmsAudio: !ProcessInfo.processInfo.arguments.contains(silentAudioLaunchArgument)
            )
            return .ready(composition)
        } catch {
            return .startupFailure(safeDescription(of: error))
        }
    }

    /// Underlying errors here are usually file-system errors, whose text
    /// carries a container path from the user's device. `DG-LOG-01` names
    /// device paths among the shapes to strip, and a failure screen is as
    /// public as a log line - it is read over shoulders and photographed into
    /// support tickets. Same scrubber, same reason.
    private static func safeDescription(of error: Error) -> String {
        RedactingLogger.scrubbedForDisplay(String(describing: error))
    }
}
