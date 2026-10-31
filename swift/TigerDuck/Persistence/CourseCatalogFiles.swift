import Foundation

/// Each term's course catalog in each language, the same for every account, so a sign-out keeps
/// it. A body runs to a few megabytes, which the Add Course sheet reads and writes off the main
/// thread, so this is not main-actor bound.
nonisolated struct CourseCatalogFiles: Sendable {
    let folders: CacheFolders

    init(folders: CacheFolders = .app) {
        self.folders = folders
    }

    func saveCourseCatalog(_ catalog: StoredCourseCatalog, semester: String, language: String) {
        let url = courseCatalogURL(semester: semester, language: language)
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(catalog).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        } catch {
            AppLogger.captureError(error, context: ["phase": "dataCache.saveCourseCatalog"])
        }
    }

    func loadCourseCatalog(semester: String, language: String) -> StoredCourseCatalog? {
        let url = courseCatalogURL(semester: semester, language: language)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try PropertyListDecoder().decode(StoredCourseCatalog.self, from: data)
        } catch {
            AppLogger.captureError(error, context: ["phase": "dataCache.loadCourseCatalog"])
            return nil
        }
    }

    private func courseCatalogURL(semester: String, language: String) -> URL {
        let term = String(semester.unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
        return folders.cache.appendingPathComponent("course_catalog_\(term)_\(language).plist")
    }
}
