# Vendored copy

The decoders of liblzma from [XZ Utils](https://github.com/tukaani-project/xz) 5.8.4 (tag `v5.8.4`,
commit `d3e650e63c110e830fd5391e7f8b45df0b91d3da`), which `../libarchive` reads 7z, xz and zipx
LZMA with. The iOS SDK ships liblzma, but without its header, so it is not public API there.

`LICENSE` is XZ Utils' `COPYING.0BSD`, unmodified: liblzma is under the BSD Zero Clause License.

## What is kept

`Sources/CLZMA/` holds, under the same paths as `src/` upstream, the `.c` files XZ Utils' CMake
build compiles for iOS with every encoder, threads and translations left out
(`-DXZ_ENCODERS="" -DXZ_THREADS=no -DXZ_NLS=OFF -DXZ_LZIP_DECODER=OFF
-DXZ_MICROLZMA_DECODER=OFF -DXZ_MICROLZMA_ENCODER=OFF`), less the ones nothing in libarchive
reaches (`easy_preset.c`, `lzma_encoder_presets.c`, `easy_decoder_memusage.c`, `file_info.c`,
`string_conversion.c`, `hardware_physmem.c`, `tuklib_physmem.c`), and every header those include.
`include/` is `src/liblzma/api`, with a module map. `Package.swift` defines what that build
passes on the command line.

## TigerDuck changes

1. `liblzma/lz/lz_decoder.c`: an LZ decoder asking for a dictionary larger than
   `TIGERDUCK_MAX_DICT_SIZE` (96 MiB) fails with `LZMA_MEMLIMIT_ERROR` instead of allocating it.
   libarchive sets no memory limit, and an archive's LZMA dictionary may ask for up to 4 GiB.
2. `Package.swift` builds the sources with `-w`, since their warnings are upstream's.

## Updating

Copy the same files from the new release over these, keep the changes above, check the defines
against a fresh CMake configure, then run `ArchiveReaderTests`.
