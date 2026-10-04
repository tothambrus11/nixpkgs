// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Demo",
    targets: [
        .target(name: "Lib"),
        .executableTarget(name: "App", dependencies: ["Lib"]),
    ]
)
