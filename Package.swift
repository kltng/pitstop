// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "pitstop",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "PitStop",
            path: "Sources/PitStop",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PitStopTests",
            dependencies: ["PitStop"],
            path: "Tests/PitStopTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
