// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProximityMac",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "ProximityMac", targets: ["ProximityMacApp"]),
    ],
    targets: [
        // Pure decision logic. Foundation only, no hardware.
        .target(name: "PresenceCore"),
        // Hardware adapters: camera, idle time, microphone, speech, displays.
        .target(name: "PresenceSensors", dependencies: ["PresenceCore"], resources: [.copy("Resources/SFace.mlmodelc")]),
        // Menu bar app: runs the engine and executes its effects.
        .executableTarget(name: "ProximityMacApp", dependencies: ["PresenceCore", "PresenceSensors"]),
        .testTarget(
            name: "PresenceCoreTests",
            dependencies: ["PresenceCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "PresenceSensorsTests", dependencies: ["PresenceSensors"]),
    ]
)
