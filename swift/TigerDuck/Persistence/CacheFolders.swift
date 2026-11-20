import Foundation

nonisolated struct CacheFolders: Sendable {
    static let app = CacheFolders(
        cache: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TigerDuckCache", isDirectory: true),
        persistent: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TigerDuckData", isDirectory: true)
    )

    let cache: URL
    let persistent: URL

    init(cache: URL, persistent: URL) {
        for (dir, phase) in [(cache, "dataCache.createCacheDir"), (persistent, "dataCache.createPersistentDir")] {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                AppLogger.captureError(error, context: ["phase": phase])
            }
        }
        self.cache = cache
        self.persistent = persistent
    }

    var cacheFiles: JSONFiles { JSONFiles(directory: cache) }
    var persistentFiles: JSONFiles { JSONFiles(directory: persistent) }

    @MainActor
    func removeEverything() {
        for dir in [cache, persistent] {
            let contents = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for url in contents {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try? FileManager.default.removeItem(at: MoodleFiles(folders: self).moodleFilesDir)
    }

    func removeCacheFiles(where matches: (String) -> Bool) {
        let contents = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []
        for url in contents where url.pathExtension == "json" && matches(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// One folder's JSON files, written with `.completeFileProtectionUnlessOpen`: academic data at
/// rest stays unreadable from a backup or a jailbroken device, and "UnlessOpen" still lets a
/// background refresh rewrite a file while the device is locked.
nonisolated struct JSONFiles: Sendable {
    let directory: URL

    func url(_ filename: String) -> URL {
        directory.appendingPathComponent(filename)
    }

    func save<T: Encodable>(_ value: T, to filename: String) {
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: url(filename), options: [.atomic, .completeFileProtectionUnlessOpen])
        } catch {
            AppLogger.captureError(error, context: ["phase": "dataCache.save", "filename": filename])
        }
    }

    func load<T: Decodable>(_ filename: String) -> T? {
        let data: Data
        do {
            data = try Data(contentsOf: url(filename))
        } catch {
            let nsError = error as NSError
            if !(nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError) {
                AppLogger.captureError(error, context: ["phase": "dataCache.load.read", "filename": filename])
            }
            return nil
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            AppLogger.captureError(error, context: ["phase": "dataCache.load.decode", "filename": filename])
            return nil
        }
    }

    func remove(_ filename: String) {
        do {
            try FileManager.default.removeItem(at: url(filename))
        } catch {
            let nsError = error as NSError
            if !(nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileNoSuchFileError) {
                AppLogger.captureError(error, context: ["phase": "dataCache.clearUserScopedData", "filename": filename])
            }
        }
    }
}
