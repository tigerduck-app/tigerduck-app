import Foundation

nonisolated struct SavedDownloadFiles: Sendable {
    static let app = SavedDownloadFiles(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    )

    private static let name = "saved_downloads.json"

    let directory: URL

    /// A missing ledger is empty, and one that cannot be read throws so that nothing is written
    /// over it. One that cannot be decoded, damaged or from a newer version, is kept aside under
    /// another name and the ledger starts empty.
    func load<Entry: Decodable>() throws -> [Entry] {
        let file = directory.appending(path: Self.name)
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }
        do {
            return try JSONDecoder().decode([Entry].self, from: data)
        } catch {
            AppLogger.captureError(error, context: ["phase": "savedDownloads.load.decode"])
            try FileManager.default.moveItem(at: file, to: directory.appending(path: Self.name + "." + UUID().uuidString))
            return []
        }
    }

    func save<Entry: Encodable>(_ entries: [Entry]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        JSONFiles(directory: directory).save(entries, to: Self.name)
    }
}
