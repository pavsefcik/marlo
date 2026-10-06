// swift-tools-version: 6.4
import PackageDescription

// MARLO — a local, on-device assistant built on Apple's Foundation Models
// framework.
//
//   MarloKit  shared agent, tools, and streaming contract
//   marlo     the CLI (scriptable; no GUI required)
//   MarloApp  the SwiftUI app — a menu-bar extra
//
// MarloKit and the CLI build with Command Line Tools alone. Arguments.swift uses
// the @Generable macro, which needs Xcode's FoundationModelsMacros plugin;
// without Xcode, swap it for hand-written conformances (README, "Xcode").
let package = Package(
    name: "marlo",
    platforms: [.macOS(.v27)],
    products: [
        .executable(name: "marlo", targets: ["marlo"]),
        .executable(name: "MarloApp", targets: ["MarloApp"]),
        .library(name: "MarloKit", targets: ["MarloKit"]),
    ],
    targets: [
        .target(
            name: "MarloKit",
            path: "Sources/MarloKit"
        ),
        // A tiny wrapper over the system readline (libedit) so the CLI gets
        // history and tab completion. Swift cannot touch libedit's mutable
        // globals under strict concurrency; C can.
        .target(
            name: "CReadline",
            path: "Sources/CReadline"
        ),
        .executableTarget(
            name: "marlo",
            dependencies: ["MarloKit", "CReadline"],
            path: "Sources/MarloCLI"
        ),
        .executableTarget(
            name: "MarloApp",
            dependencies: ["MarloKit"],
            path: "Sources/MarloUI"
        ),
        .testTarget(
            name: "MarloKitTests",
            dependencies: ["MarloKit"],
            path: "Tests/MarloKitTests"
        ),
    ]
)
