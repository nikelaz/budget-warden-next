// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "BudgetWardenAppleCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "BudgetWardenAppleCore",
            targets: ["BudgetWardenAppleCore"]
        )
    ],
    targets: [
        .target(
            name: "BudgetWardenAppleCore",
            path: "src"
        ),
        .testTarget(
            name: "BudgetWardenAppleCoreTests",
            dependencies: ["BudgetWardenAppleCore"],
            path: "Tests"
        )
    ],
    swiftLanguageModes: [.v6]
)
