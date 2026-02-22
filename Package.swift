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
        .package(url: "https://github.com/tigase/Martin.git", branch: "master"),
        .package(url: "https://github.com/tigase/MartinOMEMO.git", branch: "master"),
    ],
    targets: [
        .target(
            name: "SwitchCore",
            dependencies: [
                .product(name: "Martin", package: "Martin"),
                .product(name: "MartinOMEMO", package: "MartinOMEMO"),
            ]
        ),
        .executableTarget(
            name: "SwitchMacOS",
            dependencies: [
                "SwitchCore",
            ]
        ),
    ]
)
