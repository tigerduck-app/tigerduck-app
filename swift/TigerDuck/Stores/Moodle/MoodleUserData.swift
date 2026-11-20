import Foundation

nonisolated struct MoodleUserData: Sendable {
    let records: URL
    let downloads: URL

    @MainActor
    init(files: MoodleFiles) {
        records = files.moodleDir
        downloads = files.moodleFilesDir
    }

    @MainActor static var shared: MoodleUserData { MoodleUserData(files: .shared) }

    func measure() async -> Int {
        await Task.detached { [self] in folders().reduce(0) { $0 + FileManager.default.bytes(at: $1) } }.value
    }

    func clear() async {
        await Task.detached { [self] in
            for folder in folders() { try? FileManager.default.removeItem(at: folder) }
        }.value
    }

    private func folders() -> [URL] {
        let accounts = (try? FileManager.default.contentsOfDirectory(at: downloads, includingPropertiesForKeys: nil)) ?? []
        return [records] + accounts.map { $0.appendingPathComponent(MoodleFileDownloads.picturesFolder, isDirectory: true) }
    }
}
