import Foundation

/// One-shot migration: gives the Moodle files on the device the protection a download gets since
/// https://github.com/tigerduck-app/tigerduck-app/issues/444, closed while the device is locked.
/// Copies from before kept the default class, readable behind the lock, and stay in use until
/// Moodle lists a newer version, the user signs out or clears the downloads
/// (https://github.com/tigerduck-app/tigerduck-app/issues/503).
enum MoodleDownloadProtectMigration {
    private static let doneKey = "MoodleDownloadProtectMigration.v1.done"

    /// `protect` is replaced in tests, as a simulator keeps no protection class on a file.
    static func runIfNeeded(
        root: URL,
        protect: @escaping @Sendable (URL) throws -> Void = MoodleDownloadProtectMigration.protect(_:)
    ) async {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        let done = await Task.detached(priority: .utility) { protectFiles(in: root, protect: protect) }.value
        if done { UserDefaults.standard.set(true, forKey: doneKey) }
    }

    /// Whether every file has the class now. A file or folder that cannot be reached, as before
    /// the first unlock after a restart, leaves the pass to the next launch; one deleted meanwhile
    /// needs nothing.
    private nonisolated static func protectFiles(in root: URL, protect: (URL) throws -> Void) -> Bool {
        guard FileManager.default.fileExists(atPath: root.path) else { return true }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileProtectionKey]
        let failures = Failures()
        guard let files = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(keys), options: [],
            errorHandler: { _, error in
                if !isMissing(error) { failures.record() }
                return true
            }
        ) else { return false }
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
        return !failures.any
    }

    /// The modification date stays: `MoodleFileDownloads` reads it as the version Moodle listed.
    nonisolated static func protect(_ file: URL) throws {
        let files = FileManager.default
        var attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUnlessOpen]
        attributes[.modificationDate] = try files.attributesOfItem(atPath: file.path)[.modificationDate]
        try files.setAttributes(attributes, ofItemAtPath: file.path)
    }

    private nonisolated static func isMissing(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain
            && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
    }

    /// Set from the enumerator's error handler, which it keeps.
    private nonisolated final class Failures {
        private(set) var any = false
        func record() { any = true }
    }
}
