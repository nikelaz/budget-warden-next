// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "BWAppleCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "BWAppleCore",
            targets: ["BWAppleCore"]
        )
    ],
    dependencies: [
        .package(path: "../core/dist/apple")
    ],
    targets: [
        .target(
            name: "BWAppleCore",
            dependencies: [
                .product(name: "BWCore", package: "apple")
            ],
            path: "src"
        ),
        .testTarget(
            name: "BWAppleCoreTests",
            dependencies: ["BWAppleCore"],
            path: "tests"
        )
    ],
    swiftLanguageModes: [.v6]
)
