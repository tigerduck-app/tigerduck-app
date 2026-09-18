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
    /// Still 1 with raw sources added, deliberately. A source lands under a filename no earlier
    /// build ever wrote (`…-source.json`), so no old file is reinterpreted and nothing a new
    /// build writes is handed to an older one as a body: an older build only ever sees these
    /// files through `bodyFiles()`, which reads their size and modification date and may evict
    /// them, and never decodes one. Bumping the version instead would throw away every cached
    /// page and body on upgrade for no gain.
    static let formatVersion = 1
    private static let sharedPreferences = DefaultsMailPreferences()
    static let shared = MailCache(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SchoolMail", isDirectory: true),
        account: { MailCache.sharedPreferences.studentID }
    )

    /// `account` is the student ID the file was written for. Nothing else on disk carries an
    /// account identity — not the envelope, not the `pages/<hex folder name>.json` filename,
    /// not the payload — so without it one student's cache is indistinguishable from another's
    /// on a shared device: sign out, kill the app before the (detached) wipe finishes, and the
    /// next student's first paint is the previous student's INBOX. A colliding UIDVALIDITY
    /// would make it worse than transient, merging the two into one list and persisting that.
    /// A mismatch is treated exactly like a format-version mismatch: delete and refetch.
    private struct Envelope<Payload: Codable>: Codable {
        var version: Int
        var payload: Payload
        var account: String?
    }

    private let directory: URL
    private let bodyLimitBytes: Int
    /// A single body or source larger than this is not cached at all. Bodies and sources share
    /// the one `bodyLimitBytes` LRU budget (see `saveSource`), and an entry anywhere near the
    /// whole budget is nearly as bad as one over it: caching it evicts almost everything else
    /// just to make room for the one item. Capping a single entry at half the budget means
    /// caching one thing can never evict more than half of what is already there, so the cache
    /// always holds more than whatever was written most recently.
    private var maxEntryBytes: Int { bodyLimitBytes / 2 }
    private let account: @Sendable () -> String?
    private let lock = NSLock()
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
            writeBounded(detail, to: bodyURL(folder: folder, uidValidity: uidValidity, uid: detail.summary.uid))
        }
    }

    func bodyBytes() -> Int {
        lock.withLock { bodyFiles().reduce(0) { $0 + $1.size } }
    }

    // MARK: Raw source

    /// Kept beside the body, in the same directory and keyed the same way, so the one
    /// `bodyLimitBytes` budget and the one `pruneBodies()` sweep cover bodies and sources
    /// together. The `-source` suffix cannot collide with a body's name: a body file is
    /// `<hex folder>-<uidValidity>-<uid>.json` and none of those three pieces can contain a `-`.
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

    func saveSource(_ source: String, folder: String, uidValidity: UInt32, uid: UInt32) {
        lock.withLock {
            writeBounded(source, to: sourceURL(folder: folder, uidValidity: uidValidity, uid: uid))
        }
    }

    /// `UIDVALIDITY` changed: this folder's list, bodies and sources are meaningless now. The
    /// prefix match covers a source file too — it is named from the same folder key.
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
    ///
    /// `filename` comes from the server (RFC 2047-decoded), so `.` or `..` would otherwise
    /// resolve `appendingPathComponent` up out of this call's fresh per-attachment UUID folder —
    /// `.` back into `attachments/`, `..` a level above that. Both, and an empty name, map to a
    /// generic `attachment` instead; `/` is still replaced so nothing but the final path
    /// component can be attacker-influenced.
    func temporaryFileURL(filename: String) throws -> URL {
        let folder = directory.appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
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
              envelope.version == Self.formatVersion,
              envelope.account == account() else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return envelope.payload
    }

    /// Never throws: a failed encode or write is dropped so it can't interrupt the caller's mail
    /// operation (the network round trip already succeeded; the cache is a convenience, not the
    /// source of truth). Only the failure kind is logged, never the payload.
    private func write<T: Codable>(_ value: T, to url: URL) {
        guard let data = encoded(value) else { return }
        persist(data, to: url)
    }

    /// The bodies/sources write path: an entry over `maxEntryBytes` is skipped outright instead
    /// of being written and then swept up by `pruneBodies()`.
    ///
    /// Writing first and pruning after is what makes one huge entry destructive. It lands as the
    /// newest file, so the sweep walks the whole cache oldest-first evicting everything else to
    /// get under the limit, and then — still over it — evicts the new entry too. A 28 MB
    /// delivery-failure notice returning a base64 attachment (a real one the author received)
    /// therefore emptied the entire cache and cached nothing, on every visit. Checking the
    /// encoded size up front means an oversized entry never touches disk and never disturbs the
    /// LRU order of what is already there.
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
