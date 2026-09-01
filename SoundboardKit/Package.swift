// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SoundboardKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "GovernanceKit", targets: ["GovernanceKit"]),
        .library(name: "MediaStore", targets: ["MediaStore"]),
        .library(name: "ImportPipeline", targets: ["ImportPipeline"]),
        .library(name: "PlaybackEngine", targets: ["PlaybackEngine"]),
        .library(name: "VisualEngine", targets: ["VisualEngine"]),
        .library(name: "SoundLibrary", targets: ["SoundLibrary"]),
        .library(name: "SoundboardUI", targets: ["SoundboardUI"]),
        .executable(name: "soundboard-checks", targets: ["Checks"]),
        .executable(name: "soundboard-uat", targets: ["UAT"]),
    ],
    targets: [
        .target(name: "GovernanceKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "MediaStore", dependencies: ["GovernanceKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "ImportPipeline", dependencies: ["GovernanceKit", "MediaStore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "PlaybackEngine", dependencies: ["GovernanceKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "VisualEngine", dependencies: ["GovernanceKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "SoundLibrary",
            dependencies: ["GovernanceKit", "MediaStore", "ImportPipeline"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "SoundboardUI",
            dependencies: ["GovernanceKit", "PlaybackEngine", "VisualEngine", "SoundLibrary"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The gate suites live in a library target so that two entry points can
        // share one copy of them: the `soundboard-checks` executable, which
        // needs no test host and prints a line per assertion, and the
        // `SoundboardKitTests` XCTest target, which gives `swift test` and
        // Xcode's test navigator the same coverage. Duplicating the assertions
        // across both would guarantee they drift.
        .target(
            name: "CheckSuites",
            dependencies: ["GovernanceKit", "MediaStore", "ImportPipeline", "PlaybackEngine", "VisualEngine", "SoundLibrary", "SoundboardUI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "UAT",
            dependencies: ["GovernanceKit", "MediaStore", "ImportPipeline", "PlaybackEngine", "VisualEngine", "SoundLibrary", "SoundboardUI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Checks",
            dependencies: ["CheckSuites"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SoundboardKitTests",
            dependencies: ["CheckSuites"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
