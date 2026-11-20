import Foundation

nonisolated struct SavedDownloadFiles: Sendable {
    nonisolated struct Ledger<Entry> {
        var entries: [Entry]
        /// Written by a newer app, so this one must not write over it.
        var isNewer = false
    }

    static let app = SavedDownloadFiles(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    )

    static let version = 1
    private static let name = "saved_downloads.json"

    let directory: URL

    /// A missing ledger is empty, and one that cannot be read throws so that nothing is written
    /// over it. A record that cannot be decoded is left out; a file that is not a ledger at all is
    /// kept aside under another name and the ledger starts empty.
    func load<Entry: Decodable>() throws -> Ledger<Entry> {
        let file = directory.appending(path: Self.name)
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch CocoaError.fileReadNoSuchFile {
            return Ledger(entries: [])
        }
        do {
            guard try JSONDecoder().decode(Version.self, from: data).version <= Self.version else {
                return Ledger(entries: [], isNewer: true)
            }
            return Ledger(entries: try JSONDecoder().decode(Stored<Entry>.self, from: data).entries.compactMap(\.value))
        } catch {
            AppLogger.captureError(error, context: ["phase": "savedDownloads.load.decode"])
            try FileManager.default.moveItem(at: file, to: directory.appending(path: Self.name + "." + UUID().uuidString))
            return Ledger(entries: [])
        }
    }

    func save<Entry: Encodable>(_ entries: [Entry]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Written(version: Self.version, entries: entries))
        try data.write(to: directory.appending(path: Self.name), options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}

private struct Written<Entry: Encodable>: Encodable {
    let version: Int
    let entries: [Entry]
}

private struct Version: Decodable {
    let version: Int
}

private struct Stored<Entry: Decodable>: Decodable {
    let entries: [SkippableRecord<Entry>]
}

private struct SkippableRecord<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}
