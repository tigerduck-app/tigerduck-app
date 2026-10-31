import Foundation

enum MoodleDownloadProtectMigration {
    private static let doneKey = "MoodleDownloadProtectMigration.v1.done"
    private static let failedLaunchesKey = "MoodleDownloadProtectMigration.v1.failedLaunches"
    private static let maxFailedLaunches = 3

    static func runIfNeeded(
        root: URL,
        isProtectedDataAvailable: Bool,
        protect: @escaping @Sendable (URL) throws -> Void = MoodleDownloadProtectMigration.protect(_:)
    ) async {
        guard !AppUserDefaults.standard.bool(forKey: doneKey) else { return }
        let failures = await Task.detached(priority: .utility) { failureCount(in: root, protect: protect) }.value
        guard failures > 0 else {
            AppUserDefaults.standard.set(true, forKey: doneKey)
            return
        }
        AppLogger.breadcrumb("moodle download protection failed for \(failures) files", category: "moodle")
        guard isProtectedDataAvailable else { return }
        let failedLaunches = AppUserDefaults.standard.integer(forKey: failedLaunchesKey) + 1
        AppUserDefaults.standard.set(failedLaunches, forKey: failedLaunchesKey)
        if failedLaunches >= maxFailedLaunches {
            AppLogger.breadcrumb("moodle download protection gave up after \(failedLaunches) launches", category: "moodle")
            AppUserDefaults.standard.set(true, forKey: doneKey)
        }
    }

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

    private nonisolated final class Failures {
        private(set) var count = 0
        func record() { count += 1 }
    }
}
