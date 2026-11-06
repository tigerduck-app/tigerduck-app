#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

/// The archives are made by `tools/make_archive_fixtures.py`, from made-up files.
struct ArchiveReaderTests {
    private final class Token {}

    static let report = "\u{5831}\u{544A}.txt"
    static let big5Name = "\u{4F5C}\u{696D}\u{8AAA}\u{660E}.txt"
    static let notes = Data("Office hours moved to Thursday.\n".utf8)
    static let pdfSize = 589
    static let sameTree = [
        "archive-sample.zip", "archive-sample.7z", "archive-sample.rar", "archive-sample-v4.rar",
        "archive-sample.tar", "archive-sample.tar.gz", "archive-sample.tar.bz2", "archive-sample.tar.xz",
    ]

    static func fixture(_ name: String) throws -> URL {
        try #require(Bundle(for: Token.self).url(forResource: name, withExtension: nil))
    }

    static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ArchiveReaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func problem(_ body: () throws -> Void) -> ArchiveProblem? {
        do {
            try body()
            return nil
        } catch {
            return error as? ArchiveProblem
        }
    }

    @Test("zip, 7z, RAR 5 and 4 and tar, plain or compressed, list the same folder and files", arguments: sameTree)
    func listsEveryFormat(name: String) throws {
        let listing = try ArchiveReader.list(Self.fixture(name))
        let paths = Set(listing.items.map(\.path))
        #expect(paths.isSuperset(of: ["docs", "docs/protocol.pdf", "README.md"]))
        #expect(paths.contains(Self.report) || paths.contains(Self.big5Name))
        let pdf = try #require(listing.items.first { $0.path == "docs/protocol.pdf" })
        #expect(pdf.size == Int64(Self.pdfSize))
        #expect(pdf.problem == nil)
        #expect(pdf.modified.map { abs($0.timeIntervalSince1970 - 1_793_698_200) < 86_400 } == true)
        #expect(listing.items.first { $0.path == "docs" }?.isDirectory == true)
        #expect(!listing.truncated)
    }

    @Test("a file taken out of each format is the file that went in, under its own name", arguments: sameTree)
    func extractsEveryFormat(name: String) throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = try Self.fixture(name)
        let item = try #require(ArchiveReader.list(archive).items.first { $0.path == "docs/protocol.pdf" })
        let file = try ArchiveReader.extract(item, from: archive, into: folder)
        #expect(file.lastPathComponent == "protocol.pdf")
        #expect(file.path.hasPrefix(folder.path))
        #expect(try Data(contentsOf: file).starts(with: Data("%PDF-1.4".utf8)))
    }

    @Test("a zip's name written in Big5 without the UTF-8 flag reads as Chinese, as a RAR 4's does",
          arguments: ["archive-sample.zip", "archive-sample-v4.rar"])
    func big5Names(name: String) throws {
        let paths = try ArchiveReader.list(Self.fixture(name)).items.map(\.path)
        #expect(paths.contains(Self.big5Name))
    }

    @Test("an entry climbing out with .. is left out, and a link can't be opened",
          arguments: ["archive-sample.zip", "archive-sample.tar"])
    func traversalAndLinks(name: String) throws {
        let listing = try ArchiveReader.list(Self.fixture(name))
        #expect(!listing.items.contains { $0.path.contains("escape") })
        let link = try #require(listing.items.first { $0.path == "link-to-readme" })
        #expect(link.problem == .link)
        #expect(Self.problem { _ = try ArchiveReader.extract(link, from: Self.fixture(name), into: Self.folder()) } == .link)
    }

    @Test("a file compressed on its own is listed under the archive's name without its extension",
          arguments: ["notes.txt.gz", "notes.txt.bz2", "notes.txt.xz"])
    func singleFiles(name: String) throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = try Self.fixture(name)
        let listing = try ArchiveReader.list(archive)
        #expect(listing.items.map(\.path) == ["notes.txt"])
        let file = try ArchiveReader.extract(listing.items[0], from: archive, into: folder)
        #expect(try Data(contentsOf: file) == Self.notes)
    }

    @Test("a file that grows past the size or ratio limit stops, leaving nothing behind",
          arguments: [ArchiveLimits(maxEntryBytes: 1 << 20), ArchiveLimits(ratioFreeBytes: 0)])
    func oversize(limits: ArchiveLimits) throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = try Self.fixture("archive-sample.zip")
        let zeros = try #require(ArchiveReader.list(archive).items.first { $0.path == "zeros.bin" })
        #expect(Self.problem { _ = try ArchiveReader.extract(zeros, from: archive, into: folder, limits: limits) } == .tooLarge)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        let whole = try ArchiveReader.extract(zeros, from: archive, into: folder)
        #expect(try Data(contentsOf: whole) == Data(count: 2 << 20))
    }

    @Test("past the most entries a listing holds, it stops and says so")
    func truncated() throws {
        let listing = try ArchiveReader.list(Self.fixture("archive-sample.zip"), limits: ArchiveLimits(maxItems: 3))
        #expect(listing.items.count == 3)
        #expect(listing.truncated)
    }

    @Test("a zip whose central directory runs past the limit is not read")
    func zipDirectoryLimit() throws {
        let archive = try Self.fixture("archive-sample.zip")
        #expect(Self.problem { _ = try ArchiveReader.list(archive, limits: ArchiveLimits(maxZipDirectoryBytes: 64)) } == .tooMany)
    }

    @Test("encrypted entries show as locked and are not taken out",
          arguments: ["archive-password.zip", "archive-password.7z"])
    func passwords(name: String) throws {
        let archive = try Self.fixture(name)
        let readme = try #require(ArchiveReader.list(archive).items.first { $0.path == "README.md" })
        #expect(readme.problem == .password)
        #expect(Self.problem { _ = try ArchiveReader.extract(readme, from: archive, into: Self.folder()) } == .password)
    }

    @Test("a 7z whose names are encrypted too can't be listed")
    func encryptedNames() throws {
        let archive = try Self.fixture("archive-locked-names.7z")
        #expect(Self.problem { _ = try ArchiveReader.list(archive) } == .password)
    }

    @Test("a decoder asking for more memory than a preview may hold is refused",
          arguments: ["archive-big-dictionary.7z", "archive-big-ppmd.7z"])
    func decoderMemory(name: String) throws {
        let archive = try Self.fixture(name)
        let readme = try #require(ArchiveReader.list(archive).items.first { $0.path == "README.md" })
        #expect(Self.problem { _ = try ArchiveReader.extract(readme, from: archive, into: Self.folder()) } == .tooLarge)
    }

    @Test("bytes that are no archive are unsupported, and a stopped or late pass ends")
    func notAnArchiveAndStops() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let junk = folder.appending(path: "junk.zip")
        try Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }).write(to: junk)
        #expect(Self.problem { _ = try ArchiveReader.list(junk) } == .unsupported)
        let empty = folder.appending(path: "empty.7z")
        try Data().write(to: empty)
        #expect(Self.problem { _ = try ArchiveReader.list(empty) } != nil)

        let archive = try Self.fixture("archive-sample.tar.gz")
        #expect(Self.problem { _ = try ArchiveReader.list(archive, limits: ArchiveLimits(timeLimit: .zero)) } == .tooLarge)
        let stopped = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return Result { try ArchiveReader.list(archive) }
        }
        let result = await stopped.value
        #expect(throws: CancellationError.self) { try result.get() }
    }

    @Test("a cut or damaged archive of each format fails as a problem, never a crash", arguments: sameTree)
    func damaged(name: String) throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = try Data(contentsOf: Self.fixture(name))
        let cuts = Set(stride(from: 0, to: data.count, by: max(1, data.count / 24)) + [data.count - 1])
        var copies = cuts.map { Data(data.prefix($0)) }
        for at in stride(from: 0, to: data.count, by: max(1, data.count / 24)) {
            var flipped = data
            flipped[at] ^= 0xA5
            copies.append(flipped)
        }
        let limits = ArchiveLimits(timeLimit: .seconds(5))
        for (number, copy) in copies.enumerated() {
            let damaged = folder.appending(path: "\(number)-\(name)")
            try copy.write(to: damaged)
            do {
                for item in try ArchiveReader.list(damaged, limits: limits).items where !item.isDirectory && item.problem == nil {
                    _ = try? ArchiveReader.extract(item, from: damaged, into: folder, limits: limits)
                }
            } catch {
                #expect(error is ArchiveProblem, "\(number)-\(name): \(error)")
            }
        }
    }

    @Test("paths are shown with / between folders, without empty or . parts, and never climb out")
    func normalizedPaths() {
        #expect(ArchiveReader.normalized("/etc/./notes//a.txt") == "etc/notes/a.txt")
        #expect(ArchiveReader.normalized("docs\\week1\\a.pdf") == "docs/week1/a.pdf")
        #expect(ArchiveReader.normalized("docs/../../a.pdf") == nil)
        #expect(ArchiveReader.normalized("./") == nil)
        #expect(ArchiveReader.fileName(for: String(repeating: "\u{8AB2}", count: 90) + ".pdf") == "file.pdf")
        #expect(ArchiveReader.fileName(for: "protocol.pdf") == "protocol.pdf")
    }

    @Test("folders come first, each sorted as Files sorts, and a folder only a file names still shows")
    func tree() {
        func item(_ index: Int, _ path: String, directory: Bool = false) -> ArchiveItem {
            ArchiveItem(index: index, path: path, size: 1, modified: nil, isDirectory: directory, problem: nil)
        }
        let tree = ArchiveTree([
            item(0, "week10.pdf"), item(1, "week2.pdf"), item(2, "src/main.c"), item(3, "docs", directory: true),
            item(4, "docs/a/b.txt"), item(5, "empty", directory: true),
        ])
        #expect(tree.children(of: "").map(\.name) == ["docs", "empty", "src", "week2.pdf", "week10.pdf"])
        #expect(tree.children(of: "docs").map(\.name) == ["a"])
        #expect(tree.count(of: "docs/a") == 1)
        #expect(tree.count(of: "empty") == 0)
        #expect(tree.children(of: "src").map(\.id) == ["f/2"])
    }
}
#endif
