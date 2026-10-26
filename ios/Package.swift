// swift-tools-version: 6.0
// xtool (Linux/WSL) build of the iPhone preview. Xcode builds use project.yml (XcodeGen) instead.

import PackageDescription

let package = Package(
    name: "TrailMind",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "TrailMind", targets: ["TrailMind"]),
    ],
    targets: [
        .target(
            name: "TrailMind",
            path: "TrailMind",
            resources: [.process("Resources")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
