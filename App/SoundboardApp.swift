import SwiftUI
import UIKit
import GovernanceKit
import SoundboardUI

/// The app shell.
///
/// Deliberately thin: everything it would otherwise do lives in
/// `AppFlow` and `SoundboardComposition`, inside the package, where it
/// compiles and is checked. This file and `ContentHost` below are the only
/// parts of the app a build machine has to take on trust.
@main
struct SoundboardApp: App {
    /// Owns startup for the lifetime of the scene. v2.0 removed the age gate
    /// (`DG-USER-02`), so this goes straight to the board or to a failure
    /// screen explaining why it could not.
    @StateObject private var flow: AppFlow

    init() {
        // First statement in the process's own code, before a container is
        // touched and before any object graph exists. `DG-ACQ-08` says content
        // the user imports for their own board never leaves the device;
        // installing the observer here is what lets Phase B0's instrumented
        // test assert that from outside, rather than taking it on trust.
        OutboundObserver.install()

        let rootResult = Result { try SoundboardComposition.defaultRoot() }
        Self.resetStateIfRequestedByUITest(rootResult)
        _flow = StateObject(wrappedValue: AppFlow(rootResult: rootResult))
    }

    /// Wipes the app container so a UI test always starts with an empty
    /// library, rather than whatever a previous run left behind. Only ever runs when a UI test explicitly opts in via this
    /// launch argument - real launches never pass it, so this can never wipe
    /// a user's data (`DG-RET-04`: a hard reset here is fine, since it is not
    /// a substitute for the real deletion path).
    private static func resetStateIfRequestedByUITest(_ rootResult: Result<URL, Error>) {
        guard ProcessInfo.processInfo.arguments.contains("--uitest-reset-state"),
              case let .success(root) = rootResult else { return }
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var body: some Scene {
        WindowGroup {
            AppFlowHost(flow: flow)
        }
    }
}

private struct AppFlowHost: View {
    @ObservedObject var flow: AppFlow

    var body: some View {
        switch flow.phase {
        case let .ready(composition):
            ContentHost(composition: composition)
        case let .startupFailure(message):
            StartupFailureView(message: message)
        }
    }
}

/// Owns the composition for the lifetime of the scene.
private struct ContentHost: View {
    @StateObject private var composition: SoundboardComposition

    init(composition: SoundboardComposition) {
        _composition = StateObject(wrappedValue: composition)
    }

    var body: some View {
        SoundboardRootView(model: composition.model, posters: composition.posters)
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication.didReceiveMemoryWarningNotification
                )
            ) { _ in
                composition.handleMemoryPressure()
            }
    }
}

private struct StartupFailureView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Text("Soundboard could not start")
                .font(.system(size: 17, weight: .heavy))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.063, green: 0.071, blue: 0.086))
        .foregroundStyle(.white)
    }
}
