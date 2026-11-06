#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct ArchiveBrowserModelTests {
    private static func model(_ name: String) throws -> (ArchiveBrowserModel, URL) {
        let session = try ArchiveReaderTests.folder()
        return (ArchiveBrowserModel(archive: try ArchiveReaderTests.fixture(name), session: session), session)
    }

    private static func item(_ model: ArchiveBrowserModel, _ path: String) throws -> ArchiveItem {
        guard case .listed(let tree, _) = model.phase else { throw ArchiveProblem.broken }
        let folder = path.split(separator: "/").dropLast().joined(separator: "/")
        let node = tree.children(of: folder).first { if case .file(let item) = $0 { item.path == path } else { false } }
        guard case .file(let item) = node else { throw ArchiveProblem.broken }
        return item
    }

    @Test("a file opens in Quick Look from the browser's own folder, and a second tap opens the same copy")
    func opensInQuickLook() async throws {
        let (model, session) = try Self.model("archive-sample.zip")
        defer { try? FileManager.default.removeItem(at: session) }
        await model.load()
        model.open(try Self.item(model, "docs/protocol.pdf"))
        try await waitUntil { model.preview != nil }
        let first = try #require(model.preview)
        #expect(first.path.hasPrefix(session.path))
        #expect(first.lastPathComponent == "protocol.pdf")
        model.preview = nil
        model.open(try Self.item(model, "docs/protocol.pdf"))
        #expect(model.preview == first)
    }

    @Test("an HTML file goes to the share sheet, never Quick Look, and a locked one says why")
    func scriptedAndLocked() async throws {
        let (model, session) = try Self.model("archive-sample.zip")
        defer { try? FileManager.default.removeItem(at: session) }
        await model.load()
        model.open(try Self.item(model, "notes.html"))
        try await waitUntil { model.shared != nil }
        #expect(model.shared?.url.lastPathComponent == "notes.html")
        #expect(model.preview == nil)

        model.open(try Self.item(model, "link-to-readme"))
        #expect(model.problem == .link)
        #expect(model.opening == nil)
    }

    @Test("an archive that can't be read shows why, and a file that can't be taken out says why")
    func failures() async throws {
        let (locked, session) = try Self.model("archive-locked-names.7z")
        defer { try? FileManager.default.removeItem(at: session) }
        await locked.load()
        guard case .failed(let problem) = locked.phase else { Issue.record("not failed"); return }
        #expect(problem == .password)
        #expect(problem?.reason == String(localized: "file_viewer_archive_password"))

        let (big, bigSession) = try Self.model("archive-big-dictionary.7z")
        defer { try? FileManager.default.removeItem(at: bigSession) }
        await big.load()
        big.open(try Self.item(big, "README.md"))
        try await waitUntil { big.problem != nil }
        #expect(big.problem == .tooLarge)
        #expect(big.preview == nil)
    }

    @Test("opening an archive clears the folders closed browsers left, never an open one's")
    func cacheSweep() throws {
        let root = try ArchiveReaderTests.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ArchiveCache(root: root)
        let leftover = root.appending(path: "left-behind")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        let outer = cache.open(URL(filePath: "/tmp/a.zip"))
        try FileManager.default.createDirectory(at: outer.session, withIntermediateDirectories: true)
        let inner = cache.open(URL(filePath: "/tmp/b.zip"))
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(FileManager.default.fileExists(atPath: outer.session.path))
        #expect(inner.session.path.hasPrefix(root.path))
        cache.remove(outer.session)
        #expect(!FileManager.default.fileExists(atPath: outer.session.path))
    }

    @Test("archives open in the browser by their extension; Office files and pages still go to Quick Look")
    func formats() {
        for name in ["a.zip", "a.7z", "a.RAR", "a.tar", "a.tar.gz", "a.tgz", "a.tar.bz2", "a.txz", "notes.txt.xz"] {
            #expect(ArchiveFormats.isArchive(URL(filePath: "/tmp/\(name)")), "\(name)")
        }
        for name in ["a.docx", "a.pdf", "a.zip.pdf", "a"] {
            #expect(!ArchiveFormats.isArchive(URL(filePath: "/tmp/\(name)")), "\(name)")
        }
        #expect(!ArchiveFormats.isArchive(URL(string: "https://moodle2.ntust.edu.tw/a.zip")!))
        #expect(MoodleFileKind(mimeType: nil, fileName: "week1.tar.xz") == .archive)
    }
}
#endif
