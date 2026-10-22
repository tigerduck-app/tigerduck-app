#if os(iOS)
import Foundation
import os

nonisolated final class MailCache: @unchecked Sendable {
    static let formatVersion = 1
    private static let sharedPreferences = DefaultsMailPreferences()
    static let shared = MailCache(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SchoolMail", isDirectory: true),
        account: { MailCache.sharedPreferences.studentID }
    )

    private struct Envelope<Payload: Codable>: Codable {
        var version: Int
        var payload: Payload
        var account: String?
    }

    private let directory: URL
    private let bodyLimitBytes: Int
    private var maxEntryBytes: Int { bodyLimitBytes / 2 }
    private let account: @Sendable () -> String?
    private let lock = NSLock()
    private let wipes = OSAllocatedUnfairLock(initialState: 0)
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Mail.Cache")

    init(
        directory: URL,
        bodyLimitBytes: Int = MailConstants.bodyCacheLimitBytes,
        account: @escaping @Sendable () -> String? = { nil }
    ) {
        self.directory = directory
        self.bodyLimitBytes = bodyLimitBytes
        self.account = account
    }

    func pageURL(folder: String) -> URL {
        directory.appendingPathComponent("pages", isDirectory: true)
            .appendingPathComponent("\(Self.fileKey(folder)).json")
    }

    func loadPage(folder: String) -> MailFolderPage? {
        lock.withLock { read(MailFolderPage.self, at: pageURL(folder: folder)) }
    }

    func savePage(_ page: MailFolderPage, wipeCount: Int) {
        lock.withLock {
            guard isCurrent(wipeCount) else { return }
            write(page, to: pageURL(folder: page.folder))
        }
    }

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

    func saveDetail(_ detail: MailMessageDetail, folder: String, uidValidity: UInt32, wipeCount: Int) {
        lock.withLock {
            guard isCurrent(wipeCount) else { return }
            writeBounded(detail, to: bodyURL(folder: folder, uidValidity: uidValidity, uid: detail.summary.uid))
        }
    }

    func bodyBytes() -> Int {
        lock.withLock { bodyFiles().reduce(0) { $0 + $1.size } }
    }

    private func sourceURL(folder: String, uidValidity: UInt32, uid: UInt32) -> URL {
        bodiesDirectory.appendingPathComponent("\(Self.fileKey(folder))-\(uidValidity)-\(uid)-source.json")
    }

    func loadSource(folder: String, uidValidity: UInt32, uid: UInt32) -> String? {
        lock.withLock {
            let url = sourceURL(folder: folder, uidValidity: uidValidity, uid: uid)
            let source = read(String.self, at: url)
            if source != nil {
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            }
            return source
        }
    }

    func saveSource(_ source: String, folder: String, uidValidity: UInt32, uid: UInt32, wipeCount: Int) {
        lock.withLock {
            guard isCurrent(wipeCount) else { return }
            writeBounded(source, to: sourceURL(folder: folder, uidValidity: uidValidity, uid: uid))
        }
    }

    func dropFolder(_ folder: String) {
        lock.withLock {
            try? FileManager.default.removeItem(at: pageURL(folder: folder))
            let prefix = Self.fileKey(folder) + "-"
            for file in bodyFiles() where file.url.lastPathComponent.hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: file.url)
            }
        }
    }

    func temporaryFileURL(filename: String) throws -> URL {
        let attachments = directory.appendingPathComponent("attachments", isDirectory: true)
        let cutoff = Date().addingTimeInterval(-MailConstants.openedAttachmentLifetime)
        lock.withLock { removeEntries(in: attachments, modifiedBefore: cutoff) }
        let folder = attachments.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try createDirectory(folder)
        return folder.appendingPathComponent(Self.safeAttachmentName(filename))
    }

    private static func safeAttachmentName(_ filename: String) -> String {
        let replaced = filename.replacingOccurrences(of: "/", with: "_")
        guard let nonEmpty = replaced.mailNonEmpty, nonEmpty != ".", nonEmpty != ".." else {
            return "attachment"
        }
        return nonEmpty
    }

    func totalBytes() -> Int {
        lock.withLock {
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
            guard let files = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }
            ) else { return 0 }
            var total = 0
            for case let url as URL in files {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                    continue
                }
                total += values.fileSize ?? 0
            }
            return total
        }
    }

    func clearAll() {
        lock.withLock {
            wipes.withLock { $0 += 1 }
            _ = try? FileManager.default.removeItem(at: directory)
        }
    }

    var wipeCount: Int { wipes.withLock { $0 } }

    private func isCurrent(_ count: Int) -> Bool {
        count == wipeCount
    }

    private static func fileKey(_ folder: String) -> String {
        folder.utf8.map { String(format: "%02x", $0) }.joined()
    }

    private func read<T: Codable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let envelope = try? JSONDecoder().decode(Envelope<T>.self, from: data),
              envelope.version == Self.formatVersion,
              envelope.account == account() else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return envelope.payload
    }

    private func write<T: Codable>(_ value: T, to url: URL) {
        guard let data = encoded(value) else { return }
        persist(data, to: url)
    }

    private func writeBounded<T: Codable>(_ value: T, to url: URL) {
        guard let data = encoded(value) else { return }
        guard data.count <= maxEntryBytes else {
            logger.notice("Mail cache entry larger than half the body budget, not cached")
            return
        }
        persist(data, to: url)
        pruneBodies()
    }

    private func encoded<T: Codable>(_ value: T) -> Data? {
        let envelope = Envelope(version: Self.formatVersion, payload: value, account: account())
        guard let data = try? JSONEncoder().encode(envelope) else {
            logger.error("Mail cache encode failed, dropping write")
            return nil
        }
        return data
    }

    private func persist(_ data: Data, to url: URL) {
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

    private func removeEntries(in folder: URL, modifiedBefore cutoff: Date) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))) ?? []
        for entry in entries where ((try? entry.resourceValues(forKeys: keys))?.contentModificationDate ?? .distantPast) < cutoff {
            try? FileManager.default.removeItem(at: entry)
        }
    }

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
