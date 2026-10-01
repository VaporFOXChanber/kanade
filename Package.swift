// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kanade",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Kanade",
            path: "Sources/Kanade",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("MediaPlayer"),
            ]
        ),
        .testTarget(
            name: "KanadeTests",
            dependencies: ["Kanade"],
            path: "Tests/KanadeTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
