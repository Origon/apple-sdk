// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OrigonSDK",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
    ],
    products: [
        .library(name: "OrigonSDK", targets: ["OrigonSDK"]),
    ],
    targets: [
        .binaryTarget(
            name: "COrigonSDK",
            url: "https://github.com/Origon/apple-sdk/releases/download/v0.3.3/COrigonSDK.xcframework.zip",
            checksum: "6afe234a254e57e4da504075e3ef0d519671e1cdf672741d9f1bdcd0e831e096"
        ),
        .target(
            name: "OrigonSDK",
            dependencies: ["COrigonSDK"],
            path: "Sources/OrigonSDK",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("AVFAudio", .when(platforms: [.iOS])),
                .linkedFramework("AudioToolbox", .when(platforms: [.iOS])),
                .linkedFramework("CoreFoundation", .when(platforms: [.macOS])),
                .linkedFramework("AVFoundation", .when(platforms: [.macOS])),
                .linkedFramework("AudioToolbox", .when(platforms: [.macOS])),
                .linkedFramework("CoreAudio", .when(platforms: [.macOS])),
                .linkedFramework("CoreMedia", .when(platforms: [.macOS])),
                .linkedFramework("CoreVideo", .when(platforms: [.macOS])),
                .linkedFramework("VideoToolbox", .when(platforms: [.macOS])),
                .linkedFramework("ScreenCaptureKit", .when(platforms: [.macOS])),
            ]
        ),
    ]
)
