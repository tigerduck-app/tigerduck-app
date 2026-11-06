// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "xz",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "CLZMA", targets: ["CLZMA"]),
    ],
    targets: [
        .target(
            name: "CLZMA",
            path: "Sources/CLZMA",
            cSettings: [
                .headerSearchPath("common"),
                .headerSearchPath("liblzma/common"),
                .headerSearchPath("liblzma/check"),
                .headerSearchPath("liblzma/lz"),
                .headerSearchPath("liblzma/lzma"),
                .headerSearchPath("liblzma/rangecoder"),
                .headerSearchPath("liblzma/delta"),
                .headerSearchPath("liblzma/simple"),
                // What XZ Utils' CMake build defines for iOS with every encoder,
                // threads and translations left out (VENDORED.md).
                .define("HAVE_CHECK_CRC32"), .define("HAVE_CHECK_CRC64"), .define("HAVE_CHECK_SHA256"),
                .define("HAVE_DECODERS"), .define("HAVE_DECODER_LZMA1"), .define("HAVE_DECODER_LZMA2"),
                .define("HAVE_DECODER_DELTA"), .define("HAVE_DECODER_X86"), .define("HAVE_DECODER_ARM"),
                .define("HAVE_DECODER_ARMTHUMB"), .define("HAVE_DECODER_ARM64"), .define("HAVE_DECODER_POWERPC"),
                .define("HAVE_DECODER_IA64"), .define("HAVE_DECODER_SPARC"), .define("HAVE_DECODER_RISCV"),
                .define("HAVE_INTTYPES_H"), .define("HAVE_STDINT_H"), .define("HAVE_STDBOOL_H"), .define("HAVE__BOOL"),
                .define("HAVE_VISIBILITY", to: "0"), .define("HAVE___BUILTIN_BSWAPXX"),
                .define("HAVE___BUILTIN_ASSUME_ALIGNED"), .define("TUKLIB_FAST_UNALIGNED_ACCESS"),
                .define("TUKLIB_SYMBOL_PREFIX", to: "lzma_"), .define("_DARWIN_C_SOURCE"),
                // Upstream code is kept as released, so its warnings are not ours to fix.
                .unsafeFlags(["-w"]),
            ]
        ),
    ]
)
