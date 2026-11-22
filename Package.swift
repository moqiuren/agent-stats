// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentStats",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "StatsCore", type: .static, targets: ["StatsCore"]),
        .library(name: "StatsAdapters", type: .static, targets: ["StatsAdapters"]),
        .executable(name: "AgentStats", targets: ["AgentStatsApp"]),
    ],
    targets: [
        // Vendored single-file Zstandard decompressor (BSD, see Sources/CZstd/LICENSE-ZSTD.txt).
        // macOS ships no zstd library, so compressed host rollouts need an in-app decoder.
        .target(name: "CZstd"),
        .target(name: "StatsCore"),
        .target(name: "StatsAdapters", dependencies: ["StatsCore", "CZstd"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "AgentStatsApp", dependencies: ["StatsCore", "StatsAdapters"], linkerSettings: [.linkedFramework("AppKit")]),
        .testTarget(name: "StatsCoreTests", dependencies: ["StatsCore"]),
        .testTarget(name: "StatsAdaptersTests", dependencies: ["StatsCore", "StatsAdapters"]),
        .testTarget(name: "AgentStatsAppTests", dependencies: ["StatsCore", "StatsAdapters", "AgentStatsApp"]),
    ],
    swiftLanguageVersions: [.v5]
)
