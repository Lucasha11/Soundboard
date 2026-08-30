import SwiftUI
import UIKit
import SoundboardUI

/// The app shell.
///
/// Deliberately thin: everything it would otherwise do lives in
/// `SoundboardComposition`, inside the package, where it compiles and is
/// checked. This file and `ContentHost` below are the only parts of the app a
/// build machine has to take on trust.
@main
struct SoundboardApp: App {
    /// Built once at launch. Held as a `Result` so a container that will not
    /// open shows a visible failure instead of a board that silently does
    /// nothing.
    private let composition: Result<SoundboardComposition, Error>

    init() {
        composition = Result {
            try SoundboardComposition(root: try SoundboardComposition.defaultRoot())
        }
    }

    var body: some Scene {
        WindowGroup {
            switch composition {
            case let .success(built):
                ContentHost(composition: built)
            case let .failure(error):
                StartupFailureView(message: String(describing: error))
            }
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
