import Foundation

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
        persistent.load("course_color_map.json") ?? [:]
    }
}
