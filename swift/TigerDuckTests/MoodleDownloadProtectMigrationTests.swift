#if os(iOS)
// A simulator keeps no protection class on a file, so the tests record what the migration asks
// to protect through its `protect` seam. `doneKey` mirrors the migration's private flag, which is
// real, process-wide state: the suite is `.serialized` and `init` clears it first.
import Foundation
import Testing
@testable import TigerDuck

private let doneKey = "MoodleDownloadProtectMigration.v1.done"

@MainActor
@Suite(.serialized)
struct MoodleDownloadProtectMigrationTests {
    private final class Protected: @unchecked Sendable {
        private let lock = NSLock()
        private var files: [URL] = []
        var failing: Set<String> = []

        func record(_ file: URL) throws {
            if failing.contains(file.lastPathComponent) { throw CocoaError(.fileWriteNoPermission) }
            lock.withLock { files.append(file) }
        }

        var names: Set<String> { lock.withLock { Set(files.map(\.lastPathComponent)) } }
    }

    private let root: URL

    init() throws {
        UserDefaults.standard.removeObject(forKey: doneKey)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoodleDownloadProtectMigrationTests-\(UUID().uuidString)", isDirectory: true)
        // One download, one in another owner's folder and a member picture, as the app lays them out.
        for path in ["B11300000/20119/m5/0a1b/Week 1.pdf", "B11300000/20119/p7/2c3d/notes.txt", "B11300000/pictures/42-5"] {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("file".utf8).write(to: file)
        }
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removeObject(forKey: doneKey)
    }

    @Test func everyDownloadedFileIsProtectedOnce() async {
        defer { cleanUp() }
        let protected = Protected()

        await MoodleDownloadProtectMigration.runIfNeeded(root: root) { try protected.record($0) }
        #expect(protected.names == ["Week 1.pdf", "notes.txt", "42-5"])

        let again = Protected()
        await MoodleDownloadProtectMigration.runIfNeeded(root: root) { try again.record($0) }
        #expect(again.names.isEmpty)
    }

    /// A file that cannot take the class now, as before the first unlock after a restart, leaves
    /// the pass to the next launch.
    @Test func aFileThatFailsLeavesThePassForTheNextLaunch() async {
        defer { cleanUp() }
        let failing = Protected()
        failing.failing = ["notes.txt"]

        await MoodleDownloadProtectMigration.runIfNeeded(root: root) { try failing.record($0) }
        #expect(!UserDefaults.standard.bool(forKey: doneKey))

        let next = Protected()
        await MoodleDownloadProtectMigration.runIfNeeded(root: root) { try next.record($0) }
        #expect(next.names == ["Week 1.pdf", "notes.txt", "42-5"])
        #expect(UserDefaults.standard.bool(forKey: doneKey))
    }

    @Test func noDownloadsFolderIsDone() async {
        defer { cleanUp() }
        try? FileManager.default.removeItem(at: root)

        await MoodleDownloadProtectMigration.runIfNeeded(root: root) { _ in }
        #expect(UserDefaults.standard.bool(forKey: doneKey))
    }

    /// The modification date tells which version Moodle listed a copy in, so it stays.
    @Test func protectingKeepsTheModificationDate() throws {
        defer { cleanUp() }
        let file = root.appendingPathComponent("B11300000/20119/m5/0a1b/Week 1.pdf")
        let modified = Date(timeIntervalSince1970: 1_760_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)

        try MoodleDownloadProtectMigration.protect(file)

        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(attributes[.modificationDate] as? Date == modified)
    }
}
#endif
