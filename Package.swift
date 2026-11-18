// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Launchwatch",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LaunchwatchCore", targets: ["LaunchwatchCore"]),
        .executable(name: "Launchwatch", targets: ["Launchwatch"]),
    ],
    dependencies: [
        // The audit engine, shared with Launchcheck.
        .package(url: "https://github.com/BRIJRAJ-02/launchcheck.git", from: "0.2.1"),
    ],
    targets: [
        // UI-free watcher: pulses, audits, what counts as an event, what is due when, and the files it keeps.
        .target(name: "LaunchwatchCore", dependencies: [.product(name: "LaunchcheckCore", package: "launchcheck")], path: "Sources/LaunchwatchCore"),
        // The menu bar item and its panel.
        .executableTarget(name: "Launchwatch", dependencies: ["LaunchwatchCore"], path: "Sources/Launchwatch"),
        .testTarget(name: "LaunchwatchCoreTests", dependencies: ["LaunchwatchCore", .product(name: "LaunchcheckCore", package: "launchcheck")], path: "Tests/LaunchwatchCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
