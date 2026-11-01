import Foundation
import os

nonisolated struct OutboxFiles: Sendable {
    static let fileName = "outbox.json"
    static let parkedFileName = "outbox-parked.json"

    let directory: URL
    let read: @Sendable (URL) throws -> Data
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "CloudSync.Outbox")

    init(directory: URL, read: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }) {
        self.directory = directory
        self.read = read
    }

    static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TigerDuckCloudSync", isDirectory: true)
    }

    func load() -> (queued: [OutboxEntry], parked: [OutboxEntry])? {
        guard let queued = loadEntries(Self.fileName), let parked = loadEntries(Self.parkedFileName) else { return nil }
        return (queued, parked)
    }

    func loadReadable() -> (queued: [OutboxEntry], parked: [OutboxEntry]) {
        (loadEntries(Self.fileName) ?? [], loadEntries(Self.parkedFileName) ?? [])
    }

    func persist(queued: [OutboxEntry], parked: [OutboxEntry]) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (list, name) in [(queued, Self.fileName), (parked, Self.parkedFileName)] {
                let data = try JSONEncoder().encode(list)
                try data.write(
                    to: directory.appendingPathComponent(name),
                    options: [.atomic, .completeFileProtectionUnlessOpen]
                )
            }
        } catch {
            logger.error("Outbox: persist failed: \(error)")
        }
    }

    private struct FailableEntry: Decodable {
        let entry: OutboxEntry?
        init(from decoder: Decoder) throws {
            entry = try? OutboxEntry(from: decoder)
        }
    }

    private func loadEntries(_ fileName: String) -> [OutboxEntry]? {
        let url = directory.appendingPathComponent(fileName)
        let data: Data
        do {
            data = try read(url)
        } catch {
            return FileManager.default.fileExists(atPath: url.path) ? nil : []
        }
        guard let wrapped = try? JSONDecoder().decode([FailableEntry].self, from: data) else {
            logger.warning("\(fileName, privacy: .public) decode failed — starting empty")
            return []
        }
        let entries = wrapped.compactMap(\.entry)
        if entries.count != wrapped.count {
            logger.warning("\(fileName, privacy: .public): dropped \(wrapped.count - entries.count, privacy: .public) undecodable entries")
        }
        return entries
    }
}
