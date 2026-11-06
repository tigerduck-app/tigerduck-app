#if os(iOS)
import CryptoKit
import Foundation
import Testing
@testable import TigerDuck

struct SavedDownloadsTests {
    struct Place {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SavedDownloadsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        var folder: URL { root.appending(path: "Documents", directoryHint: .isDirectory) }
        var ledger: SavedDownloadFiles { SavedDownloadFiles(directory: root.appending(path: "Support", directoryHint: .isDirectory)) }
        let store: SavedDownloads

        init() {
            store = SavedDownloads(
                folder: root.appending(path: "Documents", directoryHint: .isDirectory),
                ledger: SavedDownloadFiles(directory: root.appending(path: "Support", directoryHint: .isDirectory))
            )
        }

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
        #expect(await place.store.entries() == [entry])
        #expect(await SavedDownloads(folder: place.folder, ledger: place.ledger).entries() == [entry])
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

        #expect(await place.store.entries() == [newer, older])
    }

    @Test func aFileTheStudentDeletedOrRenamedLeavesTheLedgerAndIsLeftAlone() async throws {
        let place = Place()
        defer { place.remove() }
        let deleted = try await place.store.save(try place.download("a"), as: "a.txt")
        let renamed = try await place.store.save(try place.download("b"), as: "b.txt")
        try FileManager.default.removeItem(at: place.store.url(of: deleted))
        try FileManager.default.moveItem(at: place.store.url(of: renamed), to: place.folder.appending(path: "mine.txt"))

        #expect(await place.store.entries().isEmpty)
        await place.store.clear()

        #expect(place.exists("mine.txt"))
        #expect(await SavedDownloads(folder: place.folder, ledger: place.ledger).entries().isEmpty)
        let recorded: [SavedDownloads.Entry] = place.ledger.load()
        #expect(recorded.isEmpty)
    }

    @Test func aFileTheStudentEditedIsNoLongerTheAppsAndIsNeverDeleted() async throws {
        let place = Place()
        defer { place.remove() }
        let entry = try await place.store.save(try place.download("hello"), as: "notes.txt")
        try Data("hellp".utf8).write(to: place.store.url(of: entry))

        #expect(await place.store.measure() == 0)
        await place.store.remove(entry)

        #expect(place.exists("notes.txt"))
        #expect(await place.store.entries().isEmpty)
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
        #expect(await place.store.entries().isEmpty)
    }

    @Test func aRemoveDeletesOnlyThatFile() async throws {
        let place = Place()
        defer { place.remove() }
        let first = try await place.store.save(try place.download("a"), as: "a.pdf")
        let second = try await place.store.save(try place.download("b"), as: "b.pdf")

        await place.store.remove(first)

        #expect(!place.exists("a.pdf"))
        #expect(await place.store.entries() == [second])
    }

    @Test func theSizeAddsOnlyFilesWhoseContentStillMatches() async throws {
        let place = Place()
        defer { place.remove() }
        _ = try place.usersOwn(String(repeating: "u", count: 1_000), named: "mine.bin")
        let kept = try await place.store.save(try place.download("aaa"), as: "a.bin")
        let edited = try await place.store.save(try place.download("bbbbb"), as: "b.bin")
        #expect(await place.store.measure() == 8)

        try Data("ccccc".utf8).write(to: place.store.url(of: edited))

        #expect(await place.store.measure() == kept.size)
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
