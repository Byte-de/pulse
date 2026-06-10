// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Pulse",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Pulse",
            path: "Sources/Pulse",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "PulseTests",
            dependencies: ["Pulse"],
            path: "Tests/PulseTests"
        ),
    ]
)
