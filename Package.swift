// swift-tools-version: 5.7

import PackageDescription

let package = Package(
    name: "Trans",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "Trans", targets: ["Trans"])
    ],
    targets: [
        .executableTarget(
            name: "Trans",
            path: "Sources/Trans"
        ),
        .testTarget(
            name: "TransTests",
            dependencies: ["Trans"],
            path: "Tests/TransTests"
        )
    ]
)
