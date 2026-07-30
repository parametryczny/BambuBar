// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BambuBar",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "BambuBar", targets: ["BambuBar"])
    ],
    targets: [
        .executableTarget(
            name: "BambuBar",
            path: "Sources/BambuBar"
        ),
        .testTarget(
            name: "BambuBarTests",
            dependencies: ["BambuBar"],
            path: "Tests/BambuBarTests"
        )
    ]
)
