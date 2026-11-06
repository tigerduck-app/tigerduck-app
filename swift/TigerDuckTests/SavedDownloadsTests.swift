#if os(iOS)
import CryptoKit
import Foundation
import os
import Testing
@testable import TigerDuck

struct SavedDownloadsTests {
    /// Counts the files the store hashes, and fails each read while `failing` is set.
    final class Reads: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: (count: 0, failing: false))

        var count: Int { state.withLock { $0.count } }

        func fail(_ failing: Bool) { state.withLock { $0.failing = failing } }

        func hash(_ file: URL) throws -> String {
            try state.withLock { state in
                state.count += 1
                if state.failing { throw CocoaError(.fileReadUnknown) }
            }
            return try SavedDownloads.sha256(of: file)
        }
    }

    struct Place {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SavedDownloadsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let reads = Reads()
        var folder: URL { root.appending(path: "Documents", directoryHint: .isDirectory) }
        var support: URL { root.appending(path: "Support", directoryHint: .isDirectory) }
        var ledger: SavedDownloadFiles { SavedDownloadFiles(directory: support) }
        var store: SavedDownloads { SavedDownloads(folder: folder, ledger: ledger, hash: reads.hash) }

        func download(_ text: String, named name: String = "download") throws -> URL {
            let folder = root.appending(path: "tmp/\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: name)
            try Data(text.utf8).write(to: file)
            return file
        }

        func usersOwn(_ text: String, named name: String) throws -> URL {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: name)
            try Data(text.utf8).write(to: file)
            return file
        }

        func exists(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: folder.appending(path: name).path(percentEncoded: false))
        }

        func touch(_ entry: SavedDownloads.Entry) throws {
            let file = try #require(store.url(of: entry))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3_600)], ofItemAtPath: file.path(percentEncoded: false))
        }

        func writeLedger(_ text: String) throws {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: support.appending(path: "saved_downloads.json"))
        }

        func supportFiles() -> [String: String] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: support.path(percentEncoded: false))) ?? []
            return Dictionary(uniqueKeysWithValues: names.map { name in
                (name, (try? String(contentsOf: support.appending(path: name), encoding: .utf8)) ?? "")
            })
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func aSavedFileMovesIntoTheFolderWithItsSizeAndHashRecorded() async throws {
        let place = Place()
        defer { place.remove() }
        let download = try place.download("hello")

        let entry = try await place.store.save(download, as: "講義.pdf")

        #expect(entry.name == "講義.pdf")
        #expect(entry.size == 5)
        #expect(entry.sha256 == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        #expect(place.exists("講義.pdf"))
        #expect(!FileManager.default.fileExists(atPath: download.path(percentEncoded: false)))
        #expect(try await place.store.entries() == [entry])
        #expect(try await SavedDownloads(folder: place.folder, ledger: place.ledger).entries() == [entry])
    }

    @Test func aTakenNameGetsTheNextFreeNumberTheWayFilesDoes() async throws {
        let place = Place()
        defer { place.remove() }
        _ = try place.usersOwn("mine", named: "講義.pdf")

        let second = try await place.store.save(try place.download("a"), as: "講義.pdf")
        let third = try await place.store.save(try place.download("b"), as: "講義.pdf")
        _ = try await place.store.save(try place.download("c"), as: "README")
        let bare = try await place.store.save(try place.download("d"), as: "README")
        let archive = try await place.store.save(try place.download("e"), as: "講義.pdf.zip")
        let archiveAgain = try await place.store.save(try place.download("f"), as: "講義.pdf.zip")

        #expect([second.name, third.name, bare.name, archive.name, archiveAgain.name]
            == ["講義 2.pdf", "講義 3.pdf", "README 2", "講義.pdf.zip", "講義.pdf 2.zip"])
        #expect(try String(contentsOf: place.folder.appending(path: "講義.pdf"), encoding: .utf8) == "mine")
    }

    @Test func entriesAreNewestFirst() async throws {
        let place = Place()
        defer { place.remove() }
        let older = try await place.store.save(try place.download("a"), as: "a.txt", at: Date(timeIntervalSince1970: 100))
        let newer = try await place.store.save(try place.download("b"), as: "b.txt", at: Date(timeIntervalSince1970: 200))

        #expect(try await place.store.entries() == [newer, older])
    }

    @Test func aFileTheStudentDeletedOrRenamedLeavesTheLedgerAndIsLeftAlone() async throws {
        let place = Place()
        defer { place.remove() }
        let deleted = try await place.store.save(try place.download("a"), as: "a.txt")
        let renamed = try await place.store.save(try place.download("b"), as: "b.txt")
        try FileManager.default.removeItem(at: try #require(place.store.url(of: deleted)))
        try FileManager.default.moveItem(at: try #require(place.store.url(of: renamed)), to: place.folder.appending(path: "mine.txt"))

        #expect(try await place.store.entries().isEmpty)
        await place.store.clear()

        #expect(place.exists("mine.txt"))
        #expect(try await SavedDownloads(folder: place.folder, ledger: place.ledger).entries().isEmpty)
        let recorded: [SavedDownloads.Entry] = try place.ledger.load()
        #expect(recorded.isEmpty)
    }

    @Test func aFileTheStudentEditedIsNoLongerTheAppsAndIsNeverDeleted() async throws {
        let place = Place()
        defer { place.remove() }
        let entry = try await place.store.save(try place.download("hello"), as: "notes.txt")
        try Data("hellp".utf8).write(to: try #require(place.store.url(of: entry)))
        try place.touch(entry)

        #expect(await place.store.measure() == 0)
        await place.store.remove(entry)

        #expect(place.exists("notes.txt"))
        #expect(try await place.store.entries().isEmpty)
    }

    @Test func clearingDeletesOnlyTheAppsFilesAndNeverOneTheStudentPutThere() async throws {
        let place = Place()
        defer { place.remove() }
        _ = try place.usersOwn("mine", named: "mine.pdf")
        _ = try await place.store.save(try place.download("a"), as: "a.pdf")
        _ = try await place.store.save(try place.download("b"), as: "b.pdf")

        await place.store.clear()

        #expect(!place.exists("a.pdf") && !place.exists("b.pdf"))
        #expect(place.exists("mine.pdf"))
        #expect(try await place.store.entries().isEmpty)
    }

    @Test func aRemoveDeletesOnlyThatFile() async throws {
        let place = Place()
        defer { place.remove() }
        let first = try await place.store.save(try place.download("a"), as: "a.pdf")
        let second = try await place.store.save(try place.download("b"), as: "b.pdf")

        await place.store.remove(first)

        #expect(!place.exists("a.pdf"))
        #expect(try await place.store.entries() == [second])
    }

    @Test func theSizeAddsOnlyFilesWhoseContentStillMatches() async throws {
        let place = Place()
        defer { place.remove() }
        _ = try place.usersOwn(String(repeating: "u", count: 1_000), named: "mine.bin")
        let kept = try await place.store.save(try place.download("aaa"), as: "a.bin")
        let edited = try await place.store.save(try place.download("bbbbb"), as: "b.bin")
        #expect(await place.store.measure() == 8)

        try Data("ccccc".utf8).write(to: try #require(place.store.url(of: edited)))
        try place.touch(edited)

        #expect(await place.store.measure() == kept.size)
    }

    @Test func aRecordStaysWhenItsFileCannotBeReadForNow() async throws {
        let place = Place()
        defer { place.remove() }
        let entry = try await place.store.save(try place.download("hello"), as: "notes.txt")
        try place.touch(entry)
        place.reads.fail(true)

        #expect(try await place.store.entries().map(\.name) == ["notes.txt"])
        #expect(await place.store.measure() == 5)
        await place.store.remove(entry)
        #expect(place.exists("notes.txt"))

        place.reads.fail(false)
        #expect(try await place.store.entries().map(\.name) == ["notes.txt"])
    }

    @Test func aFileThatIsNotChangedIsNotReadAgain() async throws {
        let place = Place()
        defer { place.remove() }
        let entry = try await place.store.save(try place.download("hello"), as: "notes.txt")
        #expect(place.reads.count == 1)

        _ = try await place.store.entries()
        _ = await place.store.measure()
        _ = try await SavedDownloads(folder: place.folder, ledger: place.ledger, hash: place.reads.hash).entries()
        #expect(place.reads.count == 1)

        try place.touch(entry)
        #expect(try await place.store.entries().map(\.name) == ["notes.txt"])
        _ = try await place.store.entries()
        #expect(place.reads.count == 2)
    }

    @Test func aRecordWrittenBeforeModificationDatesIsReadOnceThenKeepsOne() async throws {
        let place = Place()
        defer { place.remove() }
        _ = try place.usersOwn("hello", named: "notes.txt")
        try place.writeLedger("""
            [{"name":"notes.txt","size":5,"sha256":"2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824","saved":0}]
            """)

        #expect(try await place.store.entries().map(\.name) == ["notes.txt"])
        #expect(try await place.store.entries().first?.modified != nil)
        #expect(place.reads.count == 1)
    }

    @Test("a ledger that cannot be read is never written over, and nothing moves into the folder",
          arguments: ["damaged", "newer"])
    func aLedgerThatCannotBeDecodedIsKeptAside(_ shape: String) async throws {
        let place = Place()
        defer { place.remove() }
        let text = shape == "damaged"
            ? "[{\"name\":\"notes.txt\",\"size\":"
            : #"{"version":2,"entries":[{"name":"notes.txt","size":5,"sha256":"2cf2","saved":0,"tags":["week 3"]}]}"#
        try place.writeLedger(text)

        let entry = try await place.store.save(try place.download("a"), as: "a.pdf")

        let files = place.supportFiles()
        #expect(files.count == 2)
        #expect(files.values.contains(text))
        let recorded: [SavedDownloads.Entry] = try place.ledger.load()
        #expect(recorded == [entry])
    }

    @Test func aLedgerThatCannotBeOpenedStopsASaveBeforeTheFileMoves() async throws {
        let place = Place()
        defer { place.remove() }
        try FileManager.default.createDirectory(at: place.support.appending(path: "saved_downloads.json"), withIntermediateDirectories: true)
        let download = try place.download("a")

        await #expect(throws: (any Error).self) { try await place.store.save(download, as: "a.pdf") }
        await #expect(throws: (any Error).self) { try await place.store.entries() }
        #expect(await place.store.measure() == nil)

        #expect(FileManager.default.fileExists(atPath: download.path(percentEncoded: false)))
        #expect(!place.exists("a.pdf"))
    }

    @Test func aRecordNamingAnythingButAFileInTheFolderHasNoAddress() {
        let place = Place()
        defer { place.remove() }
        for name in ["../escape.pdf", "sub/a.pdf", "..", ".", ""] {
            #expect(place.store.url(of: SavedDownloads.Entry(name: name, size: 1, sha256: "", saved: .now)) == nil, "\(name)")
        }
        #expect(place.store.url(of: SavedDownloads.Entry(name: "a..b.pdf", size: 1, sha256: "", saved: .now)) != nil)
    }

    @Test func aLongNameIsShortenedToFitWithItsNumberAndExtension() async throws {
        let place = Place()
        defer { place.remove() }
        let long = String(repeating: "講", count: 100) + ".pdf"
        #expect(long.utf8.count == 304)

        let name = MoodleFileDownloads.safeName(long)
        let first = try await place.store.save(try place.download("a"), as: name)
        let second = try await place.store.save(try place.download("b"), as: name)

        #expect(name.utf8.count <= 255 && name.hasSuffix(".pdf") && name.hasPrefix("講"))
        #expect(second.name.utf8.count <= 255 && second.name.hasSuffix(" 2.pdf"))
        #expect(place.exists(first.name) && place.exists(second.name))
        #expect(MoodleFileDownloads.safeName(".hidden.pdf") == "hidden.pdf")
        #expect(MoodleFileDownloads.safeName("..") == "file")
    }

    @Test func aFileLargerThanOneReadIsHashedWhole() throws {
        let place = Place()
        defer { place.remove() }
        let file = try place.usersOwn(String(repeating: "x", count: 3 * 1_048_576 + 7), named: "large.bin")
        let whole = try Data(contentsOf: file)

        #expect(try SavedDownloads.sha256(of: file) == SHA256.hash(data: whole).map { String(format: "%02x", $0) }.joined())
    }
}
#endif
