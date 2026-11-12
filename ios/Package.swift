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
            resources: [.process("Resources")],
            linkerSettings: [
                // SwiftPM on Linux stamps the deployment target as the SDK version, which makes iOS run the app in
                // legacy compatibility mode (iPhone Duo then keeps it out from under the status bar and cameras).
                .unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "ios", "-Xlinker", "17.0", "-Xlinker", "27.1"],
                             .when(platforms: [.iOS])),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
