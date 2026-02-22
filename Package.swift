// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "mControl",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "BlockingCore", targets: ["BlockingCore"]),
        .executable(name: "mControlApp", targets: ["mControlApp"])
    ],
    targets: [
        .target(
            name: "BlockingCore"
        ),
        .executableTarget(
            name: "mControlApp",
            dependencies: ["BlockingCore"]
        ),
        .testTarget(
            name: "BlockingCoreTests",
            dependencies: ["BlockingCore"]
        ),
        .testTarget(
            name: "mControlAppTests",
            dependencies: ["mControlApp", "BlockingCore"]
        )
    ]
)
