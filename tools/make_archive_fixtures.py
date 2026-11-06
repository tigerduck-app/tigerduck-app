#!/usr/bin/env python3
"""Write the archives ArchiveReaderTests reads, into swift/TigerDuckTests/ArchiveFixtures/.

Every file is made here from made-up content: zip, tar and the compressed single files with
Python's standard library, 7z with a local 7-Zip (`7z`, p7zip 17 or later), and RAR, which no
free tool writes, by hand as stored (uncompressed) RAR 5 and RAR 4 archives following RARLAB's
format notes (https://www.rarlab.com/technote.htm). Two 7z archives then have their decoder's
memory request raised past what the app allows, with the header checksums fixed up after,
and two more 7z headers are written by hand to declare more entries and header bytes than it lists.

    python3 tools/make_archive_fixtures.py
"""

from __future__ import annotations

import bz2
import gzip
import io
import lzma
import os
import shutil
import struct
import subprocess
import tarfile
import tempfile
import zipfile
import zlib
from pathlib import Path

OUT = Path(__file__).resolve().parents[1] / "swift" / "TigerDuckTests" / "ArchiveFixtures"
MTIME = (2026, 11, 3, 9, 30, 0)
EPOCH = 1793698200  # 2026-11-03 09:30:00 UTC

def one_page_pdf(title: str) -> bytes:
    text = f"BT /F1 20 Tf 40 520 Td ({title}) Tj ET".encode()
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 420 595] /Contents 4 0 R "
        b"/Resources << /Font << /F1 5 0 R >> >> >>",
        b"<< /Length %d >>\nstream\n%s\nendstream" % (len(text), text),
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for number, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += b"%d 0 obj\n%s\nendobj\n" % (number, body)
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1)
    out += b"".join(b"%010d 00000 n \n" % offset for offset in offsets)
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objects) + 1, xref)
    return bytes(out)


PDF = one_page_pdf("Lab 4 protocol")
README = b"# Lab 4\n\nBuild with make.\n"
MAKEFILE = b"all:\n\tcc -o lab4 src/main.c\n"
MAIN_C = b"int main(void) { return 0; }\n"
REPORT = "報告.txt"  # 報告.txt
BIG5_NAME = "作業說明.txt"  # 作業說明.txt
NOTES = b"Office hours moved to Thursday.\n"


def png(width: int, height: int) -> bytes:
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    rows = b"".join(b"\x00" + b"\x3d\x9c\xf5" * width for _ in range(height))
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")


def write_zip() -> None:
    placeholder = "x" * len(BIG5_NAME.encode("big5"))
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        def add(name: str, data: bytes, mode: int = 0o644) -> None:
            info = zipfile.ZipInfo(name, MTIME)
            info.create_system = 3
            info.external_attr = (0o100000 | mode) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, data)

        folder = zipfile.ZipInfo("docs/", MTIME)
        folder.external_attr = (0o040755 << 16) | 0x10
        archive.writestr(folder, b"")
        add("docs/protocol.pdf", PDF)
        add("docs/rubric.pdf", PDF)
        add("src/main.c", MAIN_C)
        add("Makefile", MAKEFILE)
        add("README.md", README)
        add(REPORT, NOTES)
        add(placeholder, NOTES)
        add("../escape.txt", NOTES)
        add("notes.html", b"<script>alert(1)</script>\n")
        add("zeros.bin", bytes(2 << 20))
        link = zipfile.ZipInfo("link-to-readme", MTIME)
        link.create_system = 3
        link.external_attr = 0o120777 << 16
        archive.writestr(link, b"README.md")
    data = buffer.getvalue()
    # A name written in Big5 without the UTF-8 flag, as Windows in Taiwan writes it.
    data = data.replace(placeholder.encode(), BIG5_NAME.encode("big5"))
    (OUT / "archive-sample.zip").write_bytes(data)


def write_screenshot_zip() -> None:
    """The archive the on-screen tests show: a course's starter files, a three-digit folder and
    a long name among them."""
    files = {
        "docs/diagram.png": png(16, 16),
        "docs/protocol.pdf": PDF,
        "docs/report_template.docx": b"PK\x05\x06" + bytes(18),
        "docs/rubric.pdf": one_page_pdf("Rubric"),
        "src/main.c": MAIN_C,
        "src/parser.c": MAIN_C,
        "src/parser.h": b"int parse(void);\n",
        "src/queue.c": MAIN_C,
        "src/queue.h": b"int queue(void);\n",
        "tests/test_parser.c": MAIN_C,
        "tests/test_queue.c": MAIN_C,
        "Makefile": MAKEFILE,
        "README.md": README,
        "\u671f\u4e2d\u5c08\u984c\u5831\u544a_\u7b2c\u4e09\u7d44_final_revision_2026_v12.pdf": PDF,
    }
    files.update({f"samples/case{number:03}.txt": b"%d\n" % number for number in range(1, 129)})
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, data in files.items():
            info = zipfile.ZipInfo(name, MTIME)
            info.external_attr = 0o100644 << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, data)
    (OUT / "lab4_starter.zip").write_bytes(buffer.getvalue())


def write_tars() -> None:
    def tar_bytes(mode: str) -> bytes:
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode=mode, format=tarfile.PAX_FORMAT) as archive:
            def add(name: str, data: bytes) -> None:
                info = tarfile.TarInfo(name)
                info.size = len(data)
                info.mtime = EPOCH
                archive.addfile(info, io.BytesIO(data))

            folder = tarfile.TarInfo("docs")
            folder.type = tarfile.DIRTYPE
            folder.mtime = EPOCH
            archive.addfile(folder)
            add("docs/protocol.pdf", PDF)
            add("README.md", README)
            add(REPORT, NOTES)
            add("../escape.txt", NOTES)
            link = tarfile.TarInfo("link-to-readme")
            link.type = tarfile.SYMTYPE
            link.linkname = "README.md"
            archive.addfile(link)
        return buffer.getvalue()

    (OUT / "archive-sample.tar").write_bytes(tar_bytes("w"))
    (OUT / "archive-sample.tar.gz").write_bytes(tar_bytes("w:gz"))
    (OUT / "archive-sample.tar.bz2").write_bytes(tar_bytes("w:bz2"))
    (OUT / "archive-sample.tar.xz").write_bytes(tar_bytes("w:xz"))


def write_single_files() -> None:
    (OUT / "notes.txt.gz").write_bytes(gzip.compress(NOTES, mtime=EPOCH))
    (OUT / "notes.txt.bz2").write_bytes(bz2.compress(NOTES))
    (OUT / "notes.txt.xz").write_bytes(lzma.compress(NOTES))


def seven_zip(name: str, *options: str) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        stage = Path(tmp)
        (stage / "docs").mkdir()
        (stage / "docs" / "protocol.pdf").write_bytes(PDF)
        (stage / "README.md").write_bytes(README)
        (stage / REPORT).write_bytes(NOTES)
        for path in [stage / "docs", stage / "docs" / "protocol.pdf", stage / "README.md", stage / REPORT]:
            os.utime(path, (EPOCH, EPOCH))
        target = OUT / name
        target.unlink(missing_ok=True)
        subprocess.run(
            ["7z", "a", "-bd", "-y", *options, str(target), "docs", "README.md", REPORT],
            cwd=stage, check=True, stdout=subprocess.DEVNULL, env={**os.environ, "LC_ALL": "en_US.UTF-8"},
        )


def patch_7z_coders(name: str, coder: bytes, properties: bytes) -> None:
    """Gives every coder `coder` (its flag byte, id and properties' length) in a 7z whose
    header is stored plainly the properties `properties`, then fixes the start header's
    checksums, so only the memory each decoder is asked for changes."""
    path = OUT / name
    data = bytearray(path.read_bytes())
    offset, size = struct.unpack_from("<QQ", data, 12)
    start = 32 + offset
    header = bytearray(data[start:start + size])
    at = header.find(coder)
    assert at >= 0, name
    while at >= 0:
        header[at + len(coder):at + len(coder) + len(properties)] = properties
        at = header.find(coder, at + 1)
    data[start:start + size] = header
    struct.pack_into("<I", data, 28, zlib.crc32(header))
    struct.pack_into("<I", data, 8, zlib.crc32(bytes(data[12:32])))
    path.write_bytes(bytes(data))


def write_7z() -> None:
    seven_zip("archive-password.zip", "-tzip", "-pexample")
    seven_zip("archive-sample.7z", "-t7z", "-m0=lzma2", "-mx=5")
    seven_zip("archive-password.7z", "-t7z", "-m0=lzma2", "-pexample", "-mhe=off")
    seven_zip("archive-locked-names.7z", "-t7z", "-m0=lzma2", "-pexample", "-mhe=on")
    seven_zip("archive-big-dictionary.7z", "-t7z", "-m0=lzma2", "-mhc=off", "-ms=off")
    # LZMA2's one-byte dictionary size: 30 asks for 128 MiB.
    patch_7z_coders("archive-big-dictionary.7z", b"\x21\x21\x01", b"\x1e")
    seven_zip("archive-big-ppmd.7z", "-t7z", "-m0=PPMd:mem=16m:o=6", "-mhc=off", "-ms=off")
    # PPMd's order, then the size of its model: 192 MiB.
    patch_7z_coders("archive-big-ppmd.7z", b"\x23\x03\x04\x01\x05", b"\x06" + struct.pack("<I", 192 << 20))


def write_bombs() -> None:
    """A tar.bz2 and a solid 7z whose first entry, 64 MiB of zeros, packs into a few kilobytes,
    so reaching README.md after it means unpacking all of it. 7-Zip stores files in name order."""
    zeros = bytes(64 << 20)
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:bz2", format=tarfile.PAX_FORMAT) as archive:
        for name, data in [("00-zeros.bin", zeros), ("README.md", README)]:
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mtime = EPOCH
            archive.addfile(info, io.BytesIO(data))
    (OUT / "archive-bomb.tar.bz2").write_bytes(buffer.getvalue())
    with tempfile.TemporaryDirectory() as tmp:
        stage = Path(tmp)
        for name, data in [("00-zeros.bin", zeros), ("README.md", README)]:
            (stage / name).write_bytes(data)
            os.utime(stage / name, (EPOCH, EPOCH))
        target = OUT / "archive-bomb.7z"
        target.unlink(missing_ok=True)
        subprocess.run(
            ["7z", "a", "-bd", "-y", "-t7z", "-m0=lzma2", "-ms=on", str(target), "00-zeros.bin", "README.md"],
            cwd=stage, check=True, stdout=subprocess.DEVNULL, env={**os.environ, "LC_ALL": "en_US.UTF-8"},
        )


def number_7z(value: int) -> bytes:
    """7z's variable-length number: the first byte's leading one bits count the bytes after it."""
    for extra in range(8):
        high = value >> (8 * extra)
        if high < 1 << (7 - extra):
            return bytes([(0xFF00 >> extra) & 0xFF | high]) + value.to_bytes(8, "little")[:extra]
    return b"\xff" + value.to_bytes(8, "little")


def plain_7z(name: str, packed: bytes, header: bytes) -> None:
    """A 7z of the packed bytes `packed` followed by `header`, written as is, with the start
    header's offsets and checksums."""
    start = struct.pack("<QQI", len(packed), len(header), zlib.crc32(header))
    signature = b"7z\xbc\xaf\x27\x1c\x00\x04" + struct.pack("<I", zlib.crc32(start))
    (OUT / name).write_bytes(signature + start + packed + header)


def write_7z_tables() -> None:
    # kHeader and kFilesInfo declaring one entry more than the app's 100,000.
    plain_7z("archive-many-entries.7z", b"", b"\x01\x05" + number_7z(100_001) + b"\x00\x00")
    # kEncodedHeader: one 16-byte packed stream (kPackInfo), copied by coder 00 (kUnPackInfo)
    # into a header that claims to unpack to 32 MiB.
    stream = bytes(16)
    header = (
        b"\x17"
        + b"\x06\x00\x01\x09" + number_7z(len(stream)) + b"\x00"
        + b"\x07\x0b\x01\x00\x01\x01\x00\x0c" + number_7z(32 << 20) + b"\x00"
        + b"\x00"
    )
    plain_7z("archive-big-header.7z", stream, header)


def vint(value: int) -> bytes:
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        out.append(byte | (0x80 if value else 0))
        if not value:
            return bytes(out)


def rar5_header(kind: int, flags: int, body: bytes, data_size: int | None = None) -> bytes:
    fields = vint(kind) + vint(flags) + (vint(data_size) if data_size is not None else b"") + body
    sized = vint(len(fields)) + fields
    return struct.pack("<I", zlib.crc32(sized)) + sized


def write_rar5() -> None:
    out = bytearray(b"Rar!\x1a\x07\x01\x00")
    out += rar5_header(1, 0, vint(0))

    def entry(name: str, data: bytes | None) -> None:
        directory = data is None
        payload = data or b""
        file_flags = 0x0002 | (0x0001 if directory else 0x0004)
        body = vint(file_flags) + vint(len(payload)) + vint(0o40755 if directory else 0o100644)
        body += struct.pack("<I", EPOCH)
        if not directory:
            body += struct.pack("<I", zlib.crc32(payload))
        body += vint(0) + vint(1) + vint(len(name.encode())) + name.encode()
        nonlocal out
        # WinRAR marks a directory's block as carrying data too, of size 0.
        out += rar5_header(2, 0x0002, body, len(payload)) + payload

    entry("docs", None)
    entry("docs/protocol.pdf", PDF)
    entry("README.md", README)
    entry(REPORT, NOTES)
    out += rar5_header(5, 0, vint(0))
    (OUT / "archive-sample.rar").write_bytes(bytes(out))


def rar4_block(kind: int, flags: int, body: bytes) -> bytes:
    rest = struct.pack("<BHH", kind, flags, 7 + len(body)) + body
    return struct.pack("<H", zlib.crc32(rest) & 0xFFFF) + rest


def write_rar4() -> None:
    dos_time = ((MTIME[0] - 1980) << 25) | (MTIME[1] << 21) | (MTIME[2] << 16) \
        | (MTIME[3] << 11) | (MTIME[4] << 5) | (MTIME[5] // 2)
    out = bytearray(b"Rar!\x1a\x07\x00")
    out += rar4_block(0x73, 0, struct.pack("<HI", 0, 0))

    def entry(name: bytes, data: bytes | None) -> None:
        directory = data is None
        payload = data or b""
        flags = 0x8000 | (0x00E0 if directory else 0)
        body = struct.pack(
            "<IIBIIBBHI", len(payload), len(payload), 2, zlib.crc32(payload), dos_time,
            20, 0x30, len(name), 0x10 if directory else 0x20,
        ) + name
        nonlocal out
        out += rar4_block(0x74, flags, body) + payload

    entry(b"docs", None)
    entry(b"docs\\protocol.pdf", PDF)
    entry(b"README.md", README)
    entry(BIG5_NAME.encode("big5"), NOTES)
    out += rar4_block(0x7B, 0x4000, b"")
    (OUT / "archive-sample-v4.rar").write_bytes(bytes(out))


def main() -> None:
    if shutil.which("7z") is None:
        raise SystemExit("error: 7z (p7zip or 7-Zip) is needed for the 7z fixtures")
    OUT.mkdir(parents=True, exist_ok=True)
    write_zip()
    write_screenshot_zip()
    write_tars()
    write_single_files()
    write_7z()
    write_bombs()
    write_7z_tables()
    write_rar5()
    write_rar4()
    for path in sorted(OUT.iterdir()):
        print(f"{path.name}: {path.stat().st_size} bytes")


if __name__ == "__main__":
    main()
