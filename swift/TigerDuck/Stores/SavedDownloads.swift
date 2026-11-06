import CryptoKit
import Foundation

/// The student may rename, edit or add files in this folder from the Files app, so only a file whose
/// content still matches the SHA-256 recorded when it landed is measured or deleted here.
actor SavedDownloads {
    nonisolated struct Entry: Codable, Hashable, Identifiable, Sendable {
        let name: String
        let size: Int
        let sha256: String
        let saved: Date

        var id: String { name }
    }

    nonisolated static let browser = SavedDownloads(folder: .documentsDirectory, ledger: .app)

    nonisolated let folder: URL
    private let ledger: SavedDownloadFiles

    init(folder: URL, ledger: SavedDownloadFiles) {
        self.folder = folder
        self.ledger = ledger
    }

    nonisolated func url(of entry: Entry) -> URL {
        folder.appending(path: entry.name, directoryHint: .notDirectory)
    }

    func save(_ file: URL, as name: String, at date: Date = .now) throws -> Entry {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let sha256 = try Self.sha256(of: file)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let free = Self.freeName(for: name) { FileManager.default.fileExists(atPath: folder.appending(path: $0).path(percentEncoded: false)) }
        try FileManager.default.moveItem(at: file, to: folder.appending(path: free, directoryHint: .notDirectory))
        let entry = Entry(name: free, size: size, sha256: sha256, saved: date)
        ledger.save(recorded().filter { $0.name != free } + [entry])
        return entry
    }

    /// A record whose file is gone or changed leaves the ledger, and the file stays the student's.
    func entries() -> [Entry] {
        let recorded = recorded()
        let kept = recorded.filter { matches($0) }
        if kept.count != recorded.count { ledger.save(kept) }
        return kept.sorted { $0.saved > $1.saved }
    }

    func measure() -> Int {
        entries().reduce(0) { $0 + $1.size }
    }

    func remove(_ entry: Entry) {
        remove(named: [entry.name])
    }

    func clear() {
        remove(named: Set(recorded().map(\.name)))
    }

    private func remove(named names: Set<String>) {
        let recorded = recorded()
        let left = recorded.filter { entry in
            guard names.contains(entry.name) else { return true }
            guard matches(entry) else { return false }
            return (try? FileManager.default.removeItem(at: url(of: entry))) == nil
        }
        if left != recorded { ledger.save(left) }
    }

    private func recorded() -> [Entry] {
        ledger.load()
    }

    private func matches(_ entry: Entry) -> Bool {
        let file = url(of: entry)
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, values.fileSize == entry.size else { return false }
        return (try? Self.sha256(of: file)) == entry.sha256
    }

    /// The Files app numbers a copy whose name is taken: "notes.pdf", then "notes 2.pdf".
    nonisolated static func freeName(for name: String, isTaken: (String) -> Bool) -> String {
        let stem = (name as NSString).deletingPathExtension
        let suffix = (name as NSString).pathExtension
        var candidate = name
        var number = 1
        while isTaken(candidate) {
            number += 1
            candidate = suffix.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(suffix)"
        }
        return candidate
    }

    nonisolated static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try autoreleasepool(invoking: { try handle.read(upToCount: 1 << 20) }), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize()).hexEncodedString()
    }
}
