// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "swift-testing-helper",
    targets: [
        .target(name: "Greeter", path: "Sources"),
        .testTarget(name: "GreeterTests", dependencies: ["Greeter"], path: "Tests"),
    ]
)
