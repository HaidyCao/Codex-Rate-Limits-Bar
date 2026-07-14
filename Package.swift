// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexRateLimitsBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "CodexRateLimitsCore", targets: ["CodexRateLimitsCore"]),
        .executable(name: "CodexRateLimitsBar", targets: ["CodexRateLimitsBar"])
    ],
    targets: [
        .target(
            name: "CodexRateLimitsCore",
            path: "Sources/CodexRateLimitsCore"
        ),
        .executableTarget(
            name: "CodexRateLimitsBar",
            dependencies: ["CodexRateLimitsCore"],
            path: "Sources/CodexRateLimitsBar"
        ),
        .testTarget(
            name: "CodexRateLimitsCoreTests",
            dependencies: ["CodexRateLimitsCore"],
            path: "Tests/CodexRateLimitsCoreTests"
        )
    ]
)
