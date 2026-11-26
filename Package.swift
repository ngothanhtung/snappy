// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Snappy",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
    ],
    targets: [
        // Pure, dependency-free core logic — fully unit tested.
        .target(name: "SnappyCore"),
        .testTarget(
            name: "SnappyCoreTests",
            dependencies: ["SnappyCore"]
        ),
        // Runtime-resolved private display APIs (DisplayServices, IOAVService DDC,
        // MonitorPanel rotation, CGVirtualDisplay, display enable/disable).
        .target(
            name: "SnappyDisplayPrivate",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreGraphics")]
        ),
        // The menubar agent app.
        .executableTarget(
            name: "Snappy",
            dependencies: [
                "SnappyCore",
                "SnappyDisplayPrivate",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ]
        ),
    ]
)
