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
            url: "https://github.com/Origon/apple-sdk/releases/download/v0.1.0-alpha.2/COrigonSDK.xcframework.zip",
            checksum: "5fe8e3a7d7a37555928ccf1d18cfc90ce837e14fa74957599e6f9209ff1a8171"
        ),
        .target(
            name: "OrigonSDK",
            dependencies: ["COrigonSDK"],
            path: "Sources/OrigonSDK"
        ),
    ]
)
