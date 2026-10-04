// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SolarCallDesk",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SolarCallDesk", targets: ["SolarCallDesk"])],
    targets: [
        .target(name: "CallCore"),
        .target(name: "HALAudioCore", linkerSettings: [.linkedFramework("AudioToolbox")]),
        .target(name: "VoiceBridge", dependencies: ["HALAudioCore"]),
        .target(name: "CallAutomation", dependencies: ["CallCore"]),
        .target(name: "PhoneControl", dependencies: ["CallCore"]),
        .executableTarget(name: "SolarCallDesk", dependencies: ["CallCore", "VoiceBridge", "CallAutomation", "PhoneControl"]),
        .testTarget(name: "CallCoreTests", dependencies: ["CallCore"]),
        .testTarget(name: "VoiceBridgeTests", dependencies: ["VoiceBridge"])
    ]
)
