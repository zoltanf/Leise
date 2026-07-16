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
        // Pinned to an exact revision: FluidAudio is the deepest runtime dependency
        // (ASR, CTC, rescoring), and a branch pin lets any resolve silently advance
        // to untested upstream code. Bump deliberately and re-run the test suites.
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            revision: "2ea0727541135c34189194084531337a3518e1bf"
        ),
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
