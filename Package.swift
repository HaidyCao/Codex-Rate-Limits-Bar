// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexRateLimitsBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "CodexRateLimitsBar", targets: ["CodexRateLimitsBar"])
    ],
    targets: [
        .executableTarget(
            name: "CodexRateLimitsBar",
            path: "Sources/CodexRateLimitsBar"
        )
    ]
)
