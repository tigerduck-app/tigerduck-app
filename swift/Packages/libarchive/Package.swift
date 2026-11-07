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
            // Upstream code is kept as released, so its warnings are not ours to fix.
            cSettings: [.define("HAVE_CONFIG_H"), .unsafeFlags(["-w"])],
            linkerSettings: [.linkedLibrary("z"), .linkedLibrary("bz2"), .linkedLibrary("iconv")]
        ),
    ]
)
