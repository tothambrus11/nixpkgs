// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "swift-test",
    targets: [
        .target(name: "Greeter"),
        .testTarget(name: "GreeterTests", dependencies: ["Greeter"]),
    ]
)
