import Foundation

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

    /// Moodle Mobile's deep-link router honors only `?id=N` redirects reliably (the web accepts
    /// `?idnumber=`, the in-app handler does not), so deep links look the numeric id up here.
    func saveMoodleCourseIdMap(_ map: [String: Int], for signIn: SignIn) {
        guard signIn.isCurrent else { return }
        folders.persistentFiles.save(map, to: "moodle_course_id_map.json")
    }

    func loadMoodleCourseIdMap() -> [String: Int] {
        folders.persistentFiles.load("moodle_course_id_map.json") ?? [:]
    }

    func lookupMoodleCourseId(idnumber: String) -> Int? {
        guard !idnumber.isEmpty else { return nil }
        return loadMoodleCourseIdMap()[SDCourse.normalizedMoodleId(idnumber)]
    }

    func saveMoodleData<Value: Codable>(_ value: Value, fetchedAt: Date, name: String, account: String, for signIn: SignIn) {
        guard signIn.isCurrent else { return }
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
