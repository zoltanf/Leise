// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LeiseComponents",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LeiseCore", targets: ["LeiseCore"]),
        .library(name: "ParakeetEngine", targets: ["ParakeetEngine"]),
        .library(name: "FillerWordCleanup", targets: ["FillerWordCleanup"]),
        .executable(name: "OfflineModelPrep", targets: ["OfflineModelPrep"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", branch: "main"),
    ],
    targets: [
        .target(name: "LeiseCore"),
        .target(
            name: "ParakeetEngine",
            dependencies: [
                "LeiseCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            resources: [
                .process("Localizable.xcstrings"),
            ]
        ),
        .target(
            name: "FillerWordCleanup",
            dependencies: ["LeiseCore"]
        ),
        .executableTarget(
            name: "OfflineModelPrep",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .testTarget(
            name: "LeiseCoreTests",
            dependencies: ["LeiseCore"]
        ),
        .testTarget(
            name: "ParakeetEngineTests",
            dependencies: [
                "LeiseCore",
                "ParakeetEngine",
            ]
        ),
        .testTarget(
            name: "FillerWordCleanupTests",
            dependencies: [
                "LeiseCore",
                "FillerWordCleanup",
            ]
        ),
    ]
)
