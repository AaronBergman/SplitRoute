// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SplitRoute",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SplitRoute", targets: ["SplitRoute"])
    ],
    targets: [
        .executableTarget(
            name: "SplitRoute",
            path: "Sources/SplitRoute",
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "SplitRouteTests",
            dependencies: ["SplitRoute"],
            path: "Tests/SplitRouteTests"
        )
    ]
)
