// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Whisper",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "WhisperCore", targets: ["WhisperCore"]),
        .executable(name: "Whisper", targets: ["WhisperApp"]),
    ],
    targets: [
        .target(
            name: "WhisperCore"
        ),
        .executableTarget(
            name: "WhisperApp",
            dependencies: ["WhisperCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CryptoKit"),
                .linkedFramework("NaturalLanguage"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "WhisperCoreTests",
            dependencies: ["WhisperCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
