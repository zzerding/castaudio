// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CastAudio",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CastAudio",
            path: "Sources/CastAudio",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CastAudioTests",
            dependencies: ["CastAudio"],
            path: "Tests/CastAudioTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
