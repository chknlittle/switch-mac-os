// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "switch-mac-os",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "SwitchMacOS", targets: ["SwitchMacOS"]),
        .library(name: "SwitchCore", targets: ["SwitchCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/tigase/Martin.git", from: "3.2.1"),
    ],
    targets: [
        .target(
            name: "SwitchCore",
            dependencies: [
                .product(name: "Martin", package: "Martin"),
            ]
        ),
        .executableTarget(
            name: "SwitchMacOS",
            dependencies: [
                "SwitchCore",
            ]
        ),
        .testTarget(
            name: "SwitchCoreTests",
            dependencies: [
                "SwitchCore",
                .product(name: "Martin", package: "Martin"),
            ]
        ),
    ]
)
