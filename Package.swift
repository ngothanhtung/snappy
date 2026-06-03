// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Magnet",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
    ],
    targets: [
        // Pure, dependency-free core logic — fully unit tested.
        .target(name: "MagnetCore"),
        .testTarget(
            name: "MagnetCoreTests",
            dependencies: ["MagnetCore"]
        ),
        // The menubar agent app.
        .executableTarget(
            name: "Magnet",
            dependencies: [
                "MagnetCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ]
        ),
    ]
)
