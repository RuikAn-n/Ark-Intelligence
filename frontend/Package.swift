// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ArkIntelligence",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ArkIntelligence", targets: ["ArkIntelligence"])
    ],
    targets: [
        .executableTarget(
            name: "ArkIntelligence",
            path: "ArkIntelligence",
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "ArkIntelligenceTests",
            dependencies: ["ArkIntelligence"],
            path: "ArkIntelligenceTests"
        )
    ]
)
