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
        // Gate checks run as an executable because XCTest and Swift Testing both
        // require a full Xcode install, which this environment does not have.
        // Move to a testTarget once Xcode is present; the assertions port directly.
        .executableTarget(
            name: "UAT",
            dependencies: ["GovernanceKit", "MediaStore", "ImportPipeline", "PlaybackEngine", "VisualEngine", "SoundLibrary", "SoundboardUI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Checks",
            dependencies: ["GovernanceKit", "MediaStore", "ImportPipeline", "PlaybackEngine", "VisualEngine", "SoundLibrary", "SoundboardUI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
