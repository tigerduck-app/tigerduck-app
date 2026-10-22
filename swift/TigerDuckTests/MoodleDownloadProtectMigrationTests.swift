#if os(iOS)
// A simulator keeps no protection class on a file, so the tests record what the migration asks
// to protect through its `protect` seam. The keys mirror the migration's private ones, which are
// real, process-wide state: the suite is `.serialized` and `init` clears them first.
import Foundation
import Testing
@testable import TigerDuck

private let doneKey = "MoodleDownloadProtectMigration.v1.done"
private let failedLaunchesKey = "MoodleDownloadProtectMigration.v1.failedLaunches"

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
        UserDefaults.standard.removeObject(forKey: failedLaunchesKey)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoodleDownloadProtectMigrationTests-\(UUID().uuidString)", isDirectory: true)
        for path in ["B11300000/20119/m5/0a1b/Week 1.pdf", "B11300000/20119/p7/2c3d/notes.txt", "B11300000/pictures/42-5"] {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("file".utf8).write(to: file)
        }
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removeObject(forKey: doneKey)
        UserDefaults.standard.removeObject(forKey: failedLaunchesKey)
    }

    private var isDone: Bool { UserDefaults.standard.bool(forKey: doneKey) }

    private func run(_ protected: Protected, unlocked: Bool = true) async {
        await MoodleDownloadProtectMigration.runIfNeeded(root: root, isProtectedDataAvailable: unlocked) {
            try protected.record($0)
        }
    }

    @Test func everyDownloadedFileIsProtectedOnce() async {
        defer { cleanUp() }
        let protected = Protected()

        await run(protected)
        #expect(protected.names == ["Week 1.pdf", "notes.txt", "42-5"])

        let again = Protected()
        await run(again)
        #expect(again.names.isEmpty)
    }

    /// A file that cannot take the class now, as before the first unlock after a restart, leaves
    /// the pass to the next launch.
    @Test func aFileThatFailsLeavesThePassForTheNextLaunch() async {
        defer { cleanUp() }
        let failing = Protected()
        failing.failing = ["notes.txt"]

        await run(failing)
        #expect(!isDone)

        let next = Protected()
        await run(next)
        #expect(next.names == ["Week 1.pdf", "notes.txt", "42-5"])
        #expect(isDone)
    }

    @Test func aFileThatKeepsFailingWhileUnlockedEndsThePassAfterAFewLaunches() async {
        defer { cleanUp() }
        let failing = Protected()
        failing.failing = ["notes.txt"]

        for _ in 1...2 {
            await run(failing)
            #expect(!isDone)
        }
        await run(failing)
        #expect(isDone)
    }

    /// Behind the lock a file cannot take the class, which says nothing about the next launch.
    @Test func failuresBehindTheLockDoNotEndThePass() async {
        defer { cleanUp() }
        let failing = Protected()
        failing.failing = ["notes.txt"]

        for _ in 1...5 {
            await run(failing, unlocked: false)
        }
        #expect(!isDone)

        let next = Protected()
        await run(next)
        #expect(next.names == ["Week 1.pdf", "notes.txt", "42-5"])
        #expect(isDone)
    }

    @Test func noDownloadsFolderIsDone() async {
        defer { cleanUp() }
        try? FileManager.default.removeItem(at: root)

        await run(Protected())
        #expect(isDone)
    }

    /// The modification date tells which version Moodle listed a copy in. The class is set with
    /// the file's own date written back, whatever setting the class does to the date on a device.
    @Test func protectingWritesTheModificationDateBack() throws {
        defer { cleanUp() }
        let file = root.appendingPathComponent("B11300000/20119/m5/0a1b/Week 1.pdf")
        let modified = Date(timeIntervalSince1970: 1_760_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)

        let attributes = try MoodleDownloadProtectMigration.protectedAttributes(of: file)
        #expect(attributes[.protectionKey] as? FileProtectionType == .completeUnlessOpen)
        #expect(attributes[.modificationDate] as? Date == modified)

        try MoodleDownloadProtectMigration.protect(file)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date == modified)
    }
}
#endif
