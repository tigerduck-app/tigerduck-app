#if os(iOS)
import Foundation
import os

/// Versioned JSON caches for folder lists and opened mail (design doc §8.1). The server
/// is the source of truth: anything unreadable is deleted and refetched. Files are
/// protected `completeUntilFirstUserAuthentication`, so a locked-phone background check
/// can still write them, and the directory is excluded from backup.
///
/// `nonisolated`, not an `actor`: this type only serializes its own file I/O with an
/// internal lock, it does not hop actors for its callers. Callers are responsible for
/// keeping their own use of it off the main actor (background refresh, view model
/// loads on a background task) — every method here does synchronous disk I/O.
nonisolated final class MailCache: @unchecked Sendable {
    static let formatVersion = 1
    static let shared = MailCache(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SchoolMail", isDirectory: true)
    )

    private struct Envelope<Payload: Codable>: Codable {
        var version: Int
        var payload: Payload
    }

    private let directory: URL
    private let bodyLimitBytes: Int
    private let lock = NSLock()
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Mail.Cache")

    init(directory: URL, bodyLimitBytes: Int = MailConstants.bodyCacheLimitBytes) {
        self.directory = directory
        self.bodyLimitBytes = bodyLimitBytes
    }

    // MARK: Pages

    func pageURL(folder: String) -> URL {
        directory.appendingPathComponent("pages", isDirectory: true)
            .appendingPathComponent("\(Self.fileKey(folder)).json")
    }

    func loadPage(folder: String) -> MailFolderPage? {
        lock.withLock { read(MailFolderPage.self, at: pageURL(folder: folder)) }
    }

    func savePage(_ page: MailFolderPage) {
        lock.withLock { write(page, to: pageURL(folder: page.folder)) }
    }

    // MARK: Bodies

    private var bodiesDirectory: URL { directory.appendingPathComponent("bodies", isDirectory: true) }

    private func bodyURL(folder: String, uidValidity: UInt32, uid: UInt32) -> URL {
        bodiesDirectory.appendingPathComponent("\(Self.fileKey(folder))-\(uidValidity)-\(uid).json")
    }

    func loadDetail(folder: String, uidValidity: UInt32, uid: UInt32) -> MailMessageDetail? {
        lock.withLock {
            let url = bodyURL(folder: folder, uidValidity: uidValidity, uid: uid)
            let detail = read(MailMessageDetail.self, at: url)
            if detail != nil {
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            }
            return detail
        }
    }

    func saveDetail(_ detail: MailMessageDetail, folder: String, uidValidity: UInt32) {
        lock.withLock {
            write(detail, to: bodyURL(folder: folder, uidValidity: uidValidity, uid: detail.summary.uid))
            pruneBodies()
        }
    }

    func bodyBytes() -> Int {
        lock.withLock { bodyFiles().reduce(0) { $0 + $1.size } }
    }

    /// `UIDVALIDITY` changed: this folder's list and bodies are meaningless now.
    func dropFolder(_ folder: String) {
        lock.withLock {
            try? FileManager.default.removeItem(at: pageURL(folder: folder))
            let prefix = Self.fileKey(folder) + "-"
            for file in bodyFiles() where file.url.lastPathComponent.hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: file.url)
            }
        }
    }

    // MARK: Attachments

    /// A fresh file for an opened attachment; removed by `clearAll()` (sign-out).
    func temporaryFileURL(filename: String) throws -> URL {
        let folder = directory.appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try createDirectory(folder)
        let safeName = filename.replacingOccurrences(of: "/", with: "_").mailNonEmpty ?? "attachment"
        return folder.appendingPathComponent(safeName)
    }

    func clearAll() {
        lock.withLock { _ = try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: Internals

    private static func fileKey(_ folder: String) -> String {
        folder.utf8.map { String(format: "%02x", $0) }.joined()
    }

    private func read<T: Codable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let envelope = try? JSONDecoder().decode(Envelope<T>.self, from: data),
              envelope.version == Self.formatVersion else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return envelope.payload
    }

    /// Never throws: a failed encode or write is dropped so it can't interrupt the caller's mail
    /// operation (the network round trip already succeeded; the cache is a convenience, not the
    /// source of truth). Only the failure kind is logged, never the payload.
    private func write<T: Codable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(Envelope(version: Self.formatVersion, payload: value)) else {
            logger.error("Mail cache encode failed, dropping write")
            return
        }
        do {
            try createDirectory(url.deletingLastPathComponent())
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            logger.error("Mail cache write failed, dropping write: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    private func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        var root = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
    }

    private func bodyFiles() -> [(url: URL, size: Int, date: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: bodiesDirectory, includingPropertiesForKeys: keys)) ?? []
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return (url, values?.fileSize ?? 0, values?.contentModificationDate ?? .distantPast)
        }
    }

    /// Least recently used first, until the body cache fits its limit.
    private func pruneBodies() {
        var files = bodyFiles().sorted { $0.date < $1.date }
        var total = files.reduce(0) { $0 + $1.size }
        while total > bodyLimitBytes, let oldest = files.first {
            try? FileManager.default.removeItem(at: oldest.url)
            total -= oldest.size
            files.removeFirst()
        }
    }
}
#endif
