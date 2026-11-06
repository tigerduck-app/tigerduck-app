import Foundation

nonisolated struct SavedDownloadFiles: Sendable {
    static let app = SavedDownloadFiles(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    )

    let directory: URL

    func load<Entry: Decodable>() -> [Entry] {
        JSONFiles(directory: directory).load("saved_downloads.json") ?? []
    }

    func save<Entry: Encodable>(_ entries: [Entry]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        JSONFiles(directory: directory).save(entries, to: "saved_downloads.json")
    }
}
