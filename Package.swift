// swift-tools-version: 6.4
import PackageDescription

// MARLO — a local, on-device assistant built on Apple's Foundation Models
// framework. Timeline:
//
//   marlo        — CLI agent loop (this target)
//   marlo-ui     — SwiftUI menu-bar app (added once Xcode is installed, for
//                 @Generable / @State macros and Previews)
//
// Everything here builds with Command Line Tools alone. The only Xcode-only
// piece is the FoundationModelsMacros plugin, so generable argument types are
// hand-written in HandRolledGenerable.swift. See README.md.
let package = Package(
    name: "marlo",
    platforms: [.macOS(.v27)],
    products: [
        .executable(name: "marlo", targets: ["Marlo"])
    ],
    targets: [
        .executableTarget(
            name: "Marlo",
            path: "Sources/Marlo"
        )
    ]
)
