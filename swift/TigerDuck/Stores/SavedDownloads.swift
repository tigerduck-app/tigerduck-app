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
        /// The file's modification date when its hash last matched; while it is unchanged the file
        /// is not read again.
        var modified: Date?

        var id: String { name }
    }

    private enum Check {
        case same(Entry)
        case changed
        case unreadable
    }

    nonisolated static let browser = SavedDownloads(folder: .documentsDirectory, ledger: .app)

    nonisolated let folder: URL
    private let ledger: SavedDownloadFiles
    private let hash: @Sendable (URL) throws -> String
    private let values: @Sendable (URL) throws -> URLResourceValues

    init(
        folder: URL,
        ledger: SavedDownloadFiles,
        hash: @escaping @Sendable (URL) throws -> String = SavedDownloads.sha256(of:),
        values: @escaping @Sendable (URL) throws -> URLResourceValues = {
            try $0.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
        }
    ) {
        self.folder = folder
        self.ledger = ledger
        self.hash = hash
        self.values = values
    }

    nonisolated func url(of entry: Entry) -> URL? {
        let name = entry.name
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return nil }
        return folder.appending(path: name, directoryHint: .notDirectory)
    }

    func save(_ file: URL, as name: String, at date: Date = .now) throws -> Entry {
        let current: SavedDownloadFiles.Ledger<Entry> = try ledger.load()
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let sha256 = try hash(file)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let free = Self.freeName(for: name) { FileManager.default.fileExists(atPath: folder.appending(path: $0).path(percentEncoded: false)) }
        let target = folder.appending(path: free, directoryHint: .notDirectory)
        var entry = Entry(name: free, size: size, sha256: sha256, saved: date)
        guard !current.isNewer else {
            try FileManager.default.moveItem(at: file, to: target)
            return entry
        }
        let others = current.entries.filter { $0.name != free }
        try moveRecordingFirst(file, to: target, entry, besides: others)
        entry.modified = try? values(target).contentModificationDate
        try? ledger.save(others + [entry])
        return entry
    }

    private func moveRecordingFirst(_ file: URL, to target: URL, _ entry: Entry, besides others: [Entry]) throws {
        try ledger.save(others + [entry])
        do {
            try FileManager.default.moveItem(at: file, to: target)
        } catch {
            try? ledger.save(others)
            throw error
        }
    }

    /// A record whose file is gone or changed leaves the ledger, and the file stays the student's.
    /// One whose file cannot be read right now stays as it is.
    func entries() throws -> [Entry] {
        let current: SavedDownloadFiles.Ledger<Entry> = try ledger.load()
        guard !current.isNewer else { return [] }
        let recorded = current.entries
        let kept = recorded.compactMap { entry -> Entry? in
            switch check(entry) {
            case .same(let current): current
            case .unreadable: entry
            case .changed: nil
            }
        }
        if kept != recorded { try? ledger.save(kept) }
        return kept.sorted { $0.saved > $1.saved }
    }

    /// Nil while the ledger cannot be read, as for any store that could not be measured.
    func measure() -> Int? {
        (try? entries())?.reduce(0) { $0 + $1.size }
    }

    func remove(_ entry: Entry) {
        remove { $0.name == entry.name }
    }

    func clear() {
        remove { _ in true }
    }

    private func remove(where isRemoved: (Entry) -> Bool) {
        guard let current: SavedDownloadFiles.Ledger<Entry> = try? ledger.load(), !current.isNewer else { return }
        let recorded = current.entries
        let left = recorded.compactMap { entry -> Entry? in
            guard isRemoved(entry) else { return entry }
            switch check(entry) {
            case .changed: return nil
            case .unreadable: return entry
            case .same(let current):
                guard let file = url(of: current), (try? FileManager.default.removeItem(at: file)) != nil else { return current }
                return nil
            }
        }
        if left != recorded { try? ledger.save(left) }
    }

    private func check(_ entry: Entry) -> Check {
        guard let file = url(of: entry) else { return .changed }
        let values: URLResourceValues
        do {
            values = try self.values(file)
        } catch {
            return Self.isMissing(error) ? .changed : .unreadable
        }
        guard values.isRegularFile == true, values.fileSize == entry.size else { return .changed }
        if let modified = values.contentModificationDate, modified == entry.modified { return .same(entry) }
        guard let sha256 = try? hash(file) else { return .unreadable }
        guard sha256 == entry.sha256 else { return .changed }
        var current = entry
        current.modified = values.contentModificationDate
        return .same(current)
    }

    private static func isMissing(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code)
            || error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)
    }

    /// The Files app numbers a copy whose name is taken: "notes.pdf", then "notes 2.pdf".
    nonisolated static func freeName(for name: String, isTaken: (String) -> Bool) -> String {
        let (stem, suffix) = MoodleFileDownloads.nameParts(name)
        var candidate = name
        var number = 1
        while isTaken(candidate) {
            number += 1
            candidate = MoodleFileDownloads.fileName(stem, " \(number)" + suffix)
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
