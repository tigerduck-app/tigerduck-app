import Foundation

/// The account's Moodle data: the course id map, the course pages' cached answers, and the files
/// downloaded from Moodle.
final class MoodleFiles: AccountScoped {
    static let shared = MoodleFiles()

    private let folders: CacheFolders

    init(folders: CacheFolders = .app) {
        self.folders = folders
    }

    static func forgetAccount(in storage: AccountStorage) {
        let files = MoodleFiles(folders: storage.folders)
        storage.folders.persistentFiles.remove("moodle_course_id_map.json")
        try? FileManager.default.removeItem(at: files.moodleDir)
        try? FileManager.default.removeItem(at: files.moodleFilesDir)
    }

    // MARK: - Moodle course id map (idnumber to numeric id)

    /// Saved by ``AppServiceBridge`` whenever it fetches the user's enrolled courses. Moodle Mobile's
    /// deep-link router honors only `?id=N` redirects reliably (the web accepts `?idnumber=`, the
    /// in-app handler does not), so deep links look the numeric id up here. Kept in the persistent
    /// folder to survive cache sweeps of localized course data. Always overwrite the whole map with
    /// the fresh snapshot: merging would keep entries for courses the user left or whose id was
    /// reissued, and `SDCourse.moodleDeepLink` would point at a dead course.
    func saveMoodleCourseIdMap(_ map: [String: Int]) {
        folders.persistentFiles.save(map, to: "moodle_course_id_map.json")
    }

    func loadMoodleCourseIdMap() -> [String: Int] {
        folders.persistentFiles.load("moodle_course_id_map.json") ?? [:]
    }

    func lookupMoodleCourseId(idnumber: String) -> Int? {
        guard !idnumber.isEmpty else { return nil }
        // Normalised on both sides: Moodle spells a summer term "114h" and
        // NTUST "114H", and a course row can hold either spelling.
        return loadMoodleCourseIdMap()[SDCourse.normalizedMoodleId(idnumber)]
    }

    // MARK: - Course pages

    func saveMoodleData<Value: Codable>(_ value: Value, fetchedAt: Date, name: String, account: String) {
        let url = moodleFileURL(name: name, account: account)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        JSONFiles(directory: url.deletingLastPathComponent())
            .save(MoodleCacheEntry(fetchedAt: fetchedAt, value: value), to: url.lastPathComponent)
    }

    func loadMoodleData<Value: Codable>(_ type: Value.Type, name: String, account: String) -> (value: Value, fetchedAt: Date)? {
        let url = moodleFileURL(name: name, account: account)
        let entry: MoodleCacheEntry<Value>? = JSONFiles(directory: url.deletingLastPathComponent()).load(url.lastPathComponent)
        return entry.map { ($0.value, $0.fetchedAt) }
    }

    private struct MoodleCacheEntry<Value: Codable>: Codable {
        let fetchedAt: Date
        let value: Value
    }

    private var moodleDir: URL { folders.cache.appendingPathComponent("moodle", isDirectory: true) }

    /// Downloads live beside the cache folder, not in it.
    var moodleFilesDir: URL {
        folders.cache.deletingLastPathComponent().appendingPathComponent("Moodle", isDirectory: true)
    }

    private func moodleFileURL(name: String, account: String) -> URL {
        let folder = String(account.unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
        return moodleDir
            .appendingPathComponent(folder.isEmpty ? "_" : folder, isDirectory: true)
            .appendingPathComponent(name + ".json")
    }
}
