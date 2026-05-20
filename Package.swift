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
            path: "Frameworks/COrigonSDK.xcframework"
        ),
        .target(
            name: "OrigonSDK",
            dependencies: ["COrigonSDK"],
            path: "Sources/OrigonSDK"
        ),
    ]
)
