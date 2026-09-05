// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Burrow",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Burrow", targets: ["Burrow"])],
    targets: [
        .executableTarget(
            name: "Burrow",
            path: "Sources/Burrow",
            exclude: ["Info.plist"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "BurrowTests",
            dependencies: ["Burrow"],
            path: "Tests/BurrowTests",
            resources: [.process("Fixtures")]
        )
    ]
)
