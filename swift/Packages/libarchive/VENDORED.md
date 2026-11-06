# Vendored copy

The reading half of [libarchive](https://github.com/libarchive/libarchive) 3.8.11 (tag `v3.8.11`,
commit `03036ffa409a2aa1c5bbad35be2202641a040fda`), for the archive browser in
`swift/TigerDuck/Features/Archive/`. libarchive ships no Swift package, and the Swift packages
around it ship prebuilt binaries, so the sources are kept here and built with the app.

`COPYING` is libarchive's, unmodified. The files kept are under its BSD-2-Clause terms, except
`archive_blake2*`, which their headers offer under CC0 1.0, the OpenSSL licence or Apache 2.0;
CC0 is taken. Its RAR and RAR 5 readers are libarchive's own, with no code from RARLAB's unRAR.

## What is kept

`Sources/CLibArchive/` holds, from `libarchive/`, the readers for zip, 7z, RAR, RAR 5, tar and
single compressed files (raw), the gzip, bzip2 and xz filters, and what those need: the `.c`
files listed in the table below and every header they include. Nothing that writes archives or
reads or writes the disk is kept, so the code calls no `stat` or other API Apple asks a reason for.
`archive.h` and `archive_entry.h` sit in `include/`, with a module map.

| Group | Files |
| --- | --- |
| Reading | `archive_read.c`, `archive_read_set_options.c`, `archive_read_add_passphrase.c`, `archive_options.c`, `archive_check_magic.c`, `archive_virtual.c`, `archive_util.c` |
| Formats | `archive_read_support_format_{zip,7zip,rar,rar5,tar,raw}.c` |
| Filters | `archive_read_support_filter_{none,gzip,bzip2,xz}.c` |
| Entries and strings | `archive_entry.c`, `archive_entry_sparse.c`, `archive_entry_xattr.c`, `archive_acl.c`, `archive_string.c`, `archive_string_sprintf.c`, `archive_time.c`, `archive_rb.c` |
| Decoders and checks | `archive_ppmd7.c`, `archive_ppmd8.c`, `archive_crc32.c`, `archive_blake2s_ref.c`, `archive_blake2sp_ref.c`, `archive_cryptor.c`, `archive_hmac.c`, `archive_random.c` |

zlib, bzip2, iconv and CommonCrypto come from the iOS SDK; LZMA comes from `../xz`.

`config.h` is the one libarchive's CMake build writes for iOS (CMake 4.4, iPhoneOS 27.1 SDK,
deployment target 18.0), unedited:

```
cmake -G Ninja <libarchive> -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=<iPhoneOS.sdk> \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=18.0 \
  -DENABLE_OPENSSL=OFF -DENABLE_MBEDTLS=OFF -DENABLE_NETTLE=OFF -DENABLE_LIBB2=OFF \
  -DENABLE_LZ4=OFF -DENABLE_LZO=OFF -DENABLE_ZSTD=OFF -DENABLE_LIBXML2=OFF -DENABLE_EXPAT=OFF \
  -DENABLE_PCREPOSIX=OFF -DENABLE_PCRE2POSIX=OFF -DENABLE_LIBGCC=OFF -DENABLE_CNG=OFF \
  -DENABLE_TAR=OFF -DENABLE_CPIO=OFF -DENABLE_CAT=OFF -DENABLE_UNZIP=OFF -DENABLE_XATTR=OFF \
  -DENABLE_ACL=OFF -DENABLE_ICONV=ON -DENABLE_TEST=OFF -DENABLE_INSTALL=OFF -DENABLE_LZMA=ON \
  -DLIBLZMA_INCLUDE_DIR=<xz>/src/liblzma/api -DLIBLZMA_LIBRARY=<iPhoneOS.sdk>/usr/lib/liblzma.tbd
```

## TigerDuck changes

1. `archive_read_support_format_7zip.c`: a 7z PPMd coder asking for a model larger than
   `TIGERDUCK_MAX_PPMD_SIZE` (96 MiB) fails with `ENOMEM` instead of allocating it. The model's
   size comes from the archive and may be up to 4 GiB. Each of a BCJ2 folder's three sub
   streams, which upstream unpacks whole into memory before the first byte is read, is held to
   the same size and fails with `ENOMEM` before it is allocated.
2. `archive_read_support_format_7zip.c`: 7z header tables are capped before they are
   allocated, and each cap fails with `E2BIG`, which the app reports as too many entries.
   Upstream allows 100,000,000 of each and any header size, and builds every table before the
   first entry is read.
   - `TIGERDUCK_MAX_HEADER_SIZE` (16 MiB): the header's size in the start header
     (`next_header_size`), checked before any of it is read, and the size an encoded header
     unpacks to, checked before it is unpacked.
   - `TIGERDUCK_MAX_ENTRIES` (100,000): the counts of files (`numFiles`), folders
     (`numFolders`), packed streams (`numPackStreams`) and unpacked substreams
     (`unpack_streams`). Every other table, including the digests, is sized by one of these
     counts or by the header's bytes.
3. `archive_read_support_format_tar.c`: a pax extended header (`x` or `g`) whose body is larger
   than `TIGERDUCK_MAX_PAX_SIZE` (1 MiB) fails as a format error before any of it is read. Each
   entry has at most one of each, so this also caps the attributes, extended attributes
   included, kept for one entry. Upstream reads bodies up to 1 GiB and skips larger ones.
   A GNU sparse 1.0 map listing more than `TIGERDUCK_MAX_ENTRIES` (100,000) ranges fails as a
   format error before a node is allocated for each; upstream allows any count.
4. `Package.swift` builds the sources with `-w`, since their warnings are upstream's.

## Updating

Copy the same files from the new release over these, keep the changes above, run CMake again for
`config.h`, then run `ArchiveReaderTests`. Read the release notes for security fixes: this code
reads untrusted files.
