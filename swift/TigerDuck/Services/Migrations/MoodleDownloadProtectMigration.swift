import Foundation

/// One-shot migration: gives the Moodle files on the device the protection a download gets since
/// https://github.com/tigerduck-app/tigerduck-app/issues/444, closed while the device is locked.
/// Copies from before kept the default class, readable behind the lock, and stay in use until
/// Moodle lists a newer version, the user signs out or clears the downloads
/// (https://github.com/tigerduck-app/tigerduck-app/issues/503). Keep until no supported update
/// can start from 2.4.x, whose downloads it mends.
enum MoodleDownloadProtectMigration {
    private static let doneKey = "MoodleDownloadProtectMigration.v1.done"
    /// Launches with the phone unlocked that still left a file without the class.
    private static let failedLaunchesKey = "MoodleDownloadProtectMigration.v1.failedLaunches"
    /// A file that fails with the phone unlocked is unlikely to take the class at a later launch,
    /// and each launch walks the whole folder again. Giving up leaves such a file as it was:
    /// readable behind the lock and still used until Moodle lists a newer version.
    private static let maxFailedLaunches = 3

    /// `protect` is replaced in tests, as a simulator keeps no protection class on a file.
    static func runIfNeeded(
        root: URL,
        isProtectedDataAvailable: Bool,
        protect: @escaping @Sendable (URL) throws -> Void = MoodleDownloadProtectMigration.protect(_:)
    ) async {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        let failures = await Task.detached(priority: .utility) { failureCount(in: root, protect: protect) }.value
        guard failures > 0 else {
            UserDefaults.standard.set(true, forKey: doneKey)
            return
        }
        AppLogger.breadcrumb("moodle download protection failed for \(failures) files", category: "moodle")
        // Behind the lock a file may fail for want of the keys, which says nothing about the next launch.
        guard isProtectedDataAvailable else { return }
        let failedLaunches = UserDefaults.standard.integer(forKey: failedLaunchesKey) + 1
        UserDefaults.standard.set(failedLaunches, forKey: failedLaunchesKey)
        if failedLaunches >= maxFailedLaunches {
            AppLogger.breadcrumb("moodle download protection gave up after \(failedLaunches) launches", category: "moodle")
            UserDefaults.standard.set(true, forKey: doneKey)
        }
    }

    /// The files and folders left without the class. One that cannot be reached, as before the
    /// first unlock after a restart, counts; one deleted meanwhile needs nothing.
    private nonisolated static func failureCount(in root: URL, protect: (URL) throws -> Void) -> Int {
        guard FileManager.default.fileExists(atPath: root.path) else { return 0 }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileProtectionKey]
        let failures = Failures()
        guard let files = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(keys), options: [],
            errorHandler: { _, error in
                if !isMissing(error) { failures.record() }
                return true
            }
        ) else { return 1 }
        for case let file as URL in files {
            do {
                let values = try file.resourceValues(forKeys: keys)
                let protection = values.fileProtection
                guard values.isRegularFile == true, protection != .complete, protection != .completeUnlessOpen else { continue }
                try protect(file)
            } catch where isMissing(error) {
                continue
            } catch {
                failures.record()
            }
        }
        return failures.count
    }

    nonisolated static func protect(_ file: URL) throws {
        try FileManager.default.setAttributes(protectedAttributes(of: file), ofItemAtPath: file.path)
    }

    /// The class, with the file's own modification date written back: `MoodleFileDownloads`
    /// reads the date as the version Moodle listed.
    nonisolated static func protectedAttributes(of file: URL) throws -> [FileAttributeKey: Any] {
        var attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUnlessOpen]
        attributes[.modificationDate] = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]
        return attributes
    }

    private nonisolated static func isMissing(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain
            && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
    }

    /// Set from the enumerator's error handler, which it keeps.
    private nonisolated final class Failures {
        private(set) var count = 0
        func record() { count += 1 }
    }
}
