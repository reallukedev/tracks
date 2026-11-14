// swift-tools-version: 6.2
import PackageDescription

// The Rust engine, as Engine/build-apple.sh builds it: a binary XCFramework and the Swift
// bindings UniFFI generates for it. Both are build products, so they're gitignored.
let package = Package(
    name: "TracksEngine",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "TracksEngine", targets: ["TracksEngine"]),
    ],
    targets: [
        .binaryTarget(name: "TracksEngineFFI", path: "TracksEngineFFI.xcframework"),
        .target(
            name: "TracksEngine",
            dependencies: ["TracksEngineFFI"],
            // The generated bindings predate Swift 6's strict checking.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
