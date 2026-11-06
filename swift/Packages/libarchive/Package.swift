// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "libarchive",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "CLibArchive", targets: ["CLibArchive"]),
    ],
    dependencies: [
        .package(path: "../xz"),
    ],
    targets: [
        .target(
            name: "CLibArchive",
            dependencies: [.product(name: "CLZMA", package: "xz")],
            path: "Sources/CLibArchive",
            cSettings: [.define("HAVE_CONFIG_H")],
            linkerSettings: [.linkedLibrary("z"), .linkedLibrary("bz2"), .linkedLibrary("iconv")]
        ),
    ]
)
