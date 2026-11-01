import Foundation

struct ImportedClassTableFile {
    struct Contents: Codable {
        let owner: String?
        let people: [Person]
    }

    struct Person: Codable {
        let id: UUID
        let studentId: String?
        let nickname: String
        let importedAt: Date
        let sharedAt: Date?
        let terms: [Term]
    }

    struct Term: Codable {
        let semester: String
        let courseNos: [String]
        let courses: [CachedCourse]
    }

    enum Loaded {
        case missing
        case unreadable
        case contents(Contents)
    }

    let url: URL

    func load() -> Loaded {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            guard !Self.isMissingFile(error) else { return .missing }
            AppLogger.captureError(error, context: ["phase": "importedClassTables.read"])
            return .unreadable
        }
        do {
            return .contents(try JSONDecoder().decode(Contents.self, from: data))
        } catch {
            AppLogger.captureError(error, context: ["phase": "importedClassTables.decode"])
            return .unreadable
        }
    }

    func save(_ contents: Contents) -> Bool {
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let staging = try manager.url(
                for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true
            )
            defer { try? manager.removeItem(at: staging) }
            var replacement = staging.appendingPathComponent(url.lastPathComponent)
            let data = try JSONEncoder().encode(contents)
            // Readable from the first unlock after a restart, unlike the course files: the store
            // reads the file once, and a read refused while the phone is locked would leave it
            // empty for the rest of the run.
            try data.write(to: replacement, options: [.completeFileProtectionUntilFirstUserAuthentication])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try replacement.setResourceValues(values)
            if manager.fileExists(atPath: url.path) {
                _ = try manager.replaceItemAt(url, withItemAt: replacement, options: .usingNewMetadataOnly)
            } else {
                try manager.moveItem(at: replacement, to: url)
            }
            return true
        } catch {
            AppLogger.captureError(error, context: ["phase": "importedClassTables.save"])
            return false
        }
    }

    static func remove(at url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            if !isMissingFile(error) {
                AppLogger.captureError(error, context: ["phase": "importedClassTables.remove"])
            }
        }
    }

    private static func isMissingFile(_ error: any Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain
            && (nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError)
    }
}
