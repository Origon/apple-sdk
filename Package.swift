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
            url: "https://github.com/Origon/apple-sdk/releases/download/v0.2.0/COrigonSDK.xcframework.zip",
            checksum: "e01a336fa39b9720a1aa39451edca6ac6e426ed400bf884144a5726428533870"
        ),
        .target(
            name: "OrigonSDK",
            dependencies: ["COrigonSDK"],
            path: "Sources/OrigonSDK"
        ),
    ]
)
