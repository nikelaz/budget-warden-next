// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AppleCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "AppleCore",
            targets: ["AppleCore"]
        )
    ],
    targets: [
        .target(name: "AppleCore")
    ],
    swiftLanguageModes: [.v6]
)
