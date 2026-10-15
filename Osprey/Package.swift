// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Osprey",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "OspreyEngine", targets: ["OspreyEngine"]),
        .library(name: "OspreyBridge", targets: ["OspreyBridge"]),
        .library(name: "OspreyIntegration", targets: ["OspreyIntegration"]),
        .library(name: "OspreyMedia", targets: ["OspreyMedia"]),
        .library(name: "OspreyLibrary", targets: ["OspreyLibrary"]),
        .executable(name: "Osprey", targets: ["OspreyApp"]),
        .executable(name: "osprey-host", targets: ["OspreyHost"]),
    ],
    targets: [
        .target(name: "OspreyEngine"),
        .target(name: "OspreyBridge"),
        .target(name: "OspreyIntegration", dependencies: ["OspreyBridge"]),
        .target(name: "OspreyMedia", dependencies: ["OspreyEngine"]),
        .target(name: "OspreyLibrary", dependencies: ["OspreyEngine", "OspreyMedia"]),
        .executableTarget(name: "OspreyApp",
                          dependencies: ["OspreyEngine", "OspreyBridge", "OspreyIntegration", "OspreyMedia", "OspreyLibrary"]),
        .executableTarget(name: "OspreyHost", dependencies: ["OspreyBridge"]),
        .testTarget(name: "OspreyEngineTests", dependencies: ["OspreyEngine"]),
        .testTarget(name: "OspreyBridgeTests", dependencies: ["OspreyBridge"]),
        .testTarget(name: "OspreyIntegrationTests", dependencies: ["OspreyIntegration"]),
        .testTarget(name: "OspreyMediaTests", dependencies: ["OspreyMedia"], resources: [.copy("Fixtures")]),
        .testTarget(name: "OspreyLibraryTests", dependencies: ["OspreyLibrary", "OspreyEngine", "OspreyMedia"]),
    ]
)
