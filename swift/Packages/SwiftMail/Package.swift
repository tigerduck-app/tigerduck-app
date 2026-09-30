// swift-tools-version:5.9
import PackageDescription

/// Vendored copy of Cocoanetics/SwiftMail 1.11.0 (commit
/// a2d4a94f844db62843ef6aec16f3ed9462152acc), patched in place — see VENDORED.md.
/// Upstream's CLI demo executables and their SwiftDotenv/ArgumentParser dependencies
/// are dropped; TigerDuck only links the library.
let package = Package(
    name: "SwiftMail",
    platforms: [
        .macOS("12.0"),
        .iOS("15.0"),
        .tvOS("15.0"),
        .watchOS("8.0"),
        .macCatalyst("15.0")
    ],
    products: [
        .library(
            name: "SwiftMail",
            targets: ["SwiftMail"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        .package(url: "https://github.com/Cocoanetics/SwiftCross", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.101.3"),
        .package(url: "https://github.com/apple/swift-nio-imap", from: "0.3.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl", from: "2.37.1"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "SwiftMail",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOIMAP", package: "swift-nio-imap"),
                .product(name: "OrderedCollections", package: "swift-collections"),
                .product(name: "SwiftCross", package: "SwiftCross")
            ]
        ),
        .testTarget(
            name: "SwiftIMAPTests",
            dependencies: [
                "SwiftMail",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOIMAP", package: "swift-nio-imap"),
                .product(name: "Logging", package: "swift-log")
            ],
            resources: [
                .copy("Resources")
            ]
        ),
        .testTarget(
            name: "SwiftSMTPTests",
            dependencies: [
                "SwiftMail",
                .product(name: "NIOEmbedded", package: "swift-nio")
            ]
        ),
        .testTarget(
            name: "SwiftMailCoreTests",
            dependencies: [
                "SwiftMail"
            ]
        )
    ]
)
