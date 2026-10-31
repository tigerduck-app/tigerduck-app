import Foundation

/// The colour of each course and the courses whose colour the user picked. A map from before the
/// colour picker, palette indexes in `course_custom_colors.json`, is read once and rewritten as
/// colours.
nonisolated final class CourseColorFiles: AccountScoped, Sendable {
    private let persistent: JSONFiles

    init(folders: CacheFolders = .app) {
        persistent = folders.persistentFiles
    }

    static func forgetAccount(in storage: AccountStorage) {
        for name in ["course_custom_colors.json", "course_color_map.json", "picked_course_colors.json"] {
            storage.folders.persistentFiles.remove(name)
        }
    }

    func saveCourseColorMap(_ map: [String: UInt32]) {
        persistent.save(map, to: "course_color_map.json")
        if map.isEmpty { savePickedCourseColors([]) }
    }

    func loadPickedCourseColors() -> Set<String> {
        let courseNos: [String] = persistent.load("picked_course_colors.json") ?? []
        return Set(courseNos)
    }

    func savePickedCourseColors(_ courseNos: Set<String>) {
        persistent.save(courseNos.sorted(), to: "picked_course_colors.json")
    }

    func notePickedCourseColor(_ courseNo: String) {
        savePickedCourseColors(loadPickedCourseColors().union([courseNo]))
    }

    /// The per-course color map, or nil while its file exists but cannot be read, as behind the
    /// lock screen (`completeFileProtectionUnlessOpen`). A missing file is an empty map.
    func loadCourseColorMapIfReadable() -> [String: UInt32]? {
        let data: Data
        do {
            data = try Data(contentsOf: persistent.url("course_color_map.json"))
        } catch CocoaError.fileReadNoSuchFile {
            return loadCourseColorMap()
        } catch {
            return nil
        }
        return (try? JSONDecoder().decode([String: UInt32].self, from: data)) ?? loadCourseColorMap()
    }

    func loadCourseColorMap() -> [String: UInt32] {
        if let map: [String: UInt32] = persistent.load("course_color_map.json") {
            return map
        }
        let legacy: [String: Int] = persistent.load("course_custom_colors.json") ?? [:]
        guard !legacy.isEmpty else { return [:] }
        let migrated = legacy.compactMapValues { idx -> UInt32? in
            guard Self.legacyPaletteHex.indices.contains(idx) else { return nil }
            return Self.legacyPaletteHex[idx]
        }
        if !migrated.isEmpty {
            saveCourseColorMap(migrated)
        }
        return migrated
    }

    private static let legacyPaletteHex: [UInt32] = [
        0xFF6B6B, 0x4ECDC4, 0x45B7D1, 0xF39C12, 0xDDA0DD,
        0x2ECC71, 0xE74C3C, 0x3498DB, 0xF7DC6F, 0x9B59B6,
        0x1ABC9C, 0xE67E22, 0x85C1E9, 0xD35400, 0x27AE60,
        0xC0392B, 0x8E44AD, 0x16A085, 0xF1C40F, 0x2980B9,
    ]
}

extension CourseColorFiles {
    private static let hashMigrationKey = "color_hash_v2_migrated"

    /// Colours assigned before the v2 course hash are dropped once, so each course gets one again.
    func dropColorsFromBeforeHashV2() {
        guard !UserDefaults.standard.bool(forKey: Self.hashMigrationKey) else { return }
        saveCourseColorMap([:])
        UserDefaults.standard.set(true, forKey: Self.hashMigrationKey)
    }
}
