// swift-tools-version: 6.0
import PackageDescription

// Rules with no screen and no I/O that the app, the Watch app and every extension share.
let package = Package(
    name: "TigerDuckCore",
    platforms: [.iOS(.v18), .macOS(.v14), .watchOS(.v11)],
    products: [
        .library(name: "TigerDuckCore", targets: ["TigerDuckCore"]),
    ],
    targets: [
        .target(name: "TigerDuckCore"),
        .testTarget(name: "TigerDuckCoreTests", dependencies: ["TigerDuckCore"]),
    ]
)
