#if os(iOS)
import Foundation
import os

nonisolated final class MailCache: @unchecked Sendable {
    static let shared = MailCache(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SchoolMail", isDirectory: true),
        account: { MailSettingsStore.shared.studentID }
    )

    private let files: MailCacheFiles
    private let bodyLimitBytes: Int
    private var maxEntryBytes: Int { bodyLimitBytes / 2 }
    private let lock = NSLock()
    private let wipes: OSAllocatedUnfairLock<Int>
    let searchIndex: MailSearchIndex

    private var directory: URL { files.directory }

    init(
        directory: URL,
        bodyLimitBytes: Int = MailConstants.bodyCacheLimitBytes,
        account: @escaping @Sendable () -> String? = { nil }
    ) {
        files = MailCacheFiles(directory: directory, account: account)
        self.bodyLimitBytes = bodyLimitBytes
        let wipes = OSAllocatedUnfairLock(initialState: 0)
        self.wipes = wipes
        searchIndex = MailSearchIndex(
            url: directory.appendingPathComponent("search-index.sqlite"),
            account: account,
            wipeCount: { wipes.withLock { $0 } }
        )
    }

    private var pagesDirectory: URL { directory.appendingPathComponent("pages", isDirectory: true) }

    func pageURL(folder: String) -> URL {
        pagesDirectory.appendingPathComponent("\(Self.fileKey(folder)).json")
    }

    func loadPage(folder: String) -> MailFolderPage? {
        lock.withLock { read(MailFolderPage.self, at: pageURL(folder: folder)) }
    }

    func loadPages() -> [MailFolderPage] {
        let urls = lock.withLock {
            (try? FileManager.default.contentsOfDirectory(at: pagesDirectory, includingPropertiesForKeys: nil)) ?? []
        }
        var pages: [MailFolderPage] = []
        for url in urls {
            guard !Task.isCancelled else { return [] }
            guard let data = lock.withLock({ try? Data(contentsOf: url) }),
                  let page = files.decoded(MailFolderPage.self, from: data) else { continue }
            pages.append(page)
        }
        return pages
    }

    func savePage(_ page: MailFolderPage, unlessWipedSince wipeCount: Int) {
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

    func saveDetail(_ detail: MailMessageDetail, folder: String, uidValidity: UInt32, unlessWipedSince wipeCount: Int) {
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

    func saveSource(_ source: String, folder: String, uidValidity: UInt32, uid: UInt32, unlessWipedSince wipeCount: Int) {
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
        try files.createDirectory(folder)
        return folder.appendingPathComponent(Self.safeAttachmentName(filename))
    }

    func saveAttachment(_ data: Data, filename: String, unlessWipedSince wipeCount: Int) throws -> URL? {
        guard isCurrent(wipeCount) else { return nil }
        let url = try temporaryFileURL(filename: filename)
        return try lock.withLock {
            guard isCurrent(wipeCount) else { return nil }
            try files.createDirectory(url.deletingLastPathComponent())
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return url
        }
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
            searchIndex.close { _ = try? FileManager.default.removeItem(at: directory) }
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
        files.read(type, at: url)
    }

    private func write<T: Codable>(_ value: T, to url: URL) {
        guard let data = files.encoded(value) else { return }
        files.persist(data, to: url)
    }

    private func writeBounded<T: Codable>(_ value: T, to url: URL) {
        guard let data = files.encoded(value) else { return }
        guard data.count <= maxEntryBytes else {
            files.noteEntryTooLarge()
            return
        }
        files.persist(data, to: url)
        pruneBodies()
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
