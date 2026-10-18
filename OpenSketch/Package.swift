// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "OpenSketch",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "OpenSketchCore", targets: ["OpenSketchCore"]),
        .executable(name: "OpenSketch", targets: ["OpenSketch"]),
        .executable(name: "opensketch-cli", targets: ["OpenSketchCLI"])
    ],
    targets: [
        .target(
            name: "OpenSketchCore",
            path: "Sources/OpenSketchCore"
        ),
        .executableTarget(
            name: "OpenSketch",
            dependencies: ["OpenSketchCore"],
            path: "Sources/OpenSketch"
        ),
        .executableTarget(
            name: "OpenSketchCLI",
            dependencies: ["OpenSketchCore"],
            path: "Sources/OpenSketchCLI"
        ),
        .testTarget(
            name: "OpenSketchTests",
            dependencies: ["OpenSketchCore"],
            path: "Tests/OpenSketchTests"
        )
    ]
)
