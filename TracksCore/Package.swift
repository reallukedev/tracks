// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TracksCore",
    // PackageDescription has no `.v27` case yet, so these use the string form. The apps
    // themselves target iOS 27 / macOS 27 via Config/Tracks.xcconfig.
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "TracksCore", targets: ["TracksCore"]),
        .library(name: "TracksMusic", targets: ["TracksMusic"]),
    ],
    dependencies: [
        // The shared Rust engine, built by Engine/build-apple.sh.
        .package(path: "../Engine/apple/TracksEngine"),
    ],
    targets: [
        // Pure logic and models. No MusicKit, so it builds and tests without an
        // Apple Music subscription or a device. Library code is `nonisolated`;
        // callers decide where it runs.
        .target(
            name: "TracksCore",
            dependencies: [.product(name: "TracksEngine", package: "TracksEngine")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Everything that touches MusicKit lives here, behind the protocols
        // declared in TracksCore.
        .target(
            name: "TracksMusic",
            dependencies: ["TracksCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TracksCoreTests",
            dependencies: ["TracksCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TracksMusicTests",
            dependencies: ["TracksMusic"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
