import Foundation
import SwiftData

/// The app's SwiftData store, opened once per process.
enum AppModelStore {
    /// `static` so the store is opened once per process: SwiftData expects one `ModelContainer`
    /// per on-disk store, and the open (disk and schema check) runs in front of the first frame.
    static let shared: ModelContainer = {
        let schema = Schema([
            SDCourse.self,
            SDAssignment.self,
            SDAnnouncement.self,
            SDCalendarEvent.self,
        ])
        let onDisk = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        return openStore(at: onDisk.url) { inMemory in
            try ModelContainer(for: schema, configurations: [
                inMemory ? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true) : onDisk,
            ])
        }
    }()

    /// A store that fails to open is deleted and made again only when its file opens: one that
    /// does not, as before the first unlock after a restart, may read later, so this process keeps
    /// its data in memory instead (https://github.com/tigerduck-app/tigerduck-app/issues/693).
    static func openStore<Store>(at storeURL: URL, open: (_ inMemory: Bool) throws -> Store) -> Store {
        do {
            return try open(false)
        } catch {
            AppLogger.captureError(error, context: ["phase": "modelContainer.initialCreate"])
        }
        if !cannotOpenYet(storeURL) {
            deleteStoreFiles(at: storeURL)
            do {
                return try open(false)
            } catch {
                AppLogger.captureError(error, context: ["phase": "modelContainer.retryAfterReset"])
            }
        }
        do {
            return try open(true)
        } catch {
            AppLogger.captureError(error, context: ["phase": "modelContainer.inMemoryFallback"])
            fatalError("Could not create ModelContainer, on disk or in memory: \(error)")
        }
    }

    private static func cannotOpenYet(_ storeURL: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return false }
        guard let handle = try? FileHandle(forReadingFrom: storeURL) else { return true }
        try? handle.close()
        return false
    }

    /// Deletes the store and its SQLite sidecars. SQLite names them by appending "-wal" and
    /// "-shm" to the store's file name (`default.store-wal`); one left behind hands the retry
    /// the same stale data.
    static func deleteStoreFiles(at storeURL: URL) {
        let files = [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-wal"),
            URL(fileURLWithPath: storeURL.path + "-shm"),
        ]
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
