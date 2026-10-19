// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FaceLock",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FaceLockCore", targets: ["FaceLockCore"]),
        .library(name: "FaceLockVision", targets: ["FaceLockVision"]),
        .library(name: "FaceLockCapture", targets: ["FaceLockCapture"]),
        .library(name: "FaceLockSystem", targets: ["FaceLockSystem"]),
        .executable(name: "FaceLock", targets: ["FaceLock"]),
        .executable(name: "facelock-bench", targets: ["facelock-bench"]),
    ],
    targets: [
        .target(name: "FaceLockCore", path: "Sources/FaceLockCore"),
        .target(
            name: "FaceLockVision",
            dependencies: ["FaceLockCore"],
            path: "Sources/FaceLockVision"
        ),
        .target(
            name: "FaceLockCapture",
            dependencies: ["FaceLockCore", "FaceLockVision"],
            path: "Sources/FaceLockCapture"
        ),
        .target(
            name: "FaceLockSystem",
            dependencies: ["FaceLockCore"],
            path: "Sources/FaceLockSystem",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "FaceLock",
            dependencies: ["FaceLockCore", "FaceLockVision", "FaceLockCapture", "FaceLockSystem"],
            path: "Sources/FaceLock",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "facelock-bench",
            dependencies: ["FaceLockCore", "FaceLockVision", "FaceLockCapture", "FaceLockSystem"],
            path: "Sources/facelock-bench"
        ),
        .testTarget(
            name: "FaceLockCoreTests",
            dependencies: ["FaceLockCore"],
            path: "Tests/FaceLockCoreTests"
        ),
        .testTarget(
            name: "FaceLockVisionTests",
            dependencies: ["FaceLockCore", "FaceLockVision", "FaceLockCapture"],
            path: "Tests/FaceLockVisionTests"
        ),
        .testTarget(
            name: "FaceLockAppTests",
            dependencies: ["FaceLock", "FaceLockCore", "FaceLockSystem"],
            path: "Tests/FaceLockAppTests"
        ),
        .testTarget(
            name: "FaceLockSystemTests",
            dependencies: ["FaceLockCore", "FaceLockSystem"],
            path: "Tests/FaceLockSystemTests"
        ),
    ]
)
