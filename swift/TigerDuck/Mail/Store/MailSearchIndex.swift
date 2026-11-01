#if os(iOS)
import Foundation
import os
import SQLite3

/// Mail2000 answers a `SEARCH` in Chinese with `NO [BADCHARSET]`.
/// See docs/decisions/0027-mail-local-search-index.md.
nonisolated final class MailSearchIndex: @unchecked Sendable {
    private static let schemaVersion: Int64 = 1

    private let url: URL
    private let account: @Sendable () -> String?
    private let wipeCount: @Sendable () -> Int
    private let lock = NSLock()
    private var db: OpaquePointer?
    private var isDamaged = false

    init(url: URL, account: @escaping @Sendable () -> String?, wipeCount: @escaping @Sendable () -> Int) {
        self.url = url
        self.account = account
        self.wipeCount = wipeCount
    }

    deinit {
        sqlite3_close_v2(db)
    }

    func prepare(folder: String, uidValidity: UInt32, onServer: Set<UInt32>, unlessWipedSince expected: Int) -> Set<UInt32>? {
        withFileDroppedIfDamaged {
            guard expected == wipeCount(), openOrRecreateLocked() else { return nil }
            return transactionLocked { () -> Set<UInt32>? in
                guard adoptOwnerLocked() else { return nil }
                if validityLocked(folder) != uidValidity {
                    guard execute("DELETE FROM mail WHERE folder = ?", [.text(folder)]),
                          execute("INSERT OR REPLACE INTO folders (name, uid_validity) VALUES (?, ?)",
                                  [.text(folder), .int(Int64(uidValidity))]) else { return nil }
                }
                var held = Set<UInt32>()
                guard execute("SELECT uid FROM mail WHERE folder = ?", [.text(folder)], row: {
                    held.insert(UInt32(truncatingIfNeeded: sqlite3_column_int64($0, 0)))
                }) else { return nil }
                for uid in held.subtracting(onServer) {
                    guard execute("DELETE FROM mail WHERE folder = ? AND uid = ?", [.text(folder), .int(Int64(uid))]) else {
                        return nil
                    }
                }
                return held.intersection(onServer)
            }
        }
    }

    func add(_ texts: [UInt32: MailSearchText], folder: String, uidValidity: UInt32, unlessWipedSince expected: Int) -> Bool {
        withFileDroppedIfDamaged {
            guard expected == wipeCount(), openOrRecreateLocked(), ownerLocked() == currentOwner,
                  validityLocked(folder) == uidValidity else { return false }
            return transactionLocked { () -> Bool? in
                for (uid, text) in texts {
                    guard execute("INSERT OR REPLACE INTO mail (folder, uid, text) VALUES (?, ?, ?)",
                                  [.text(folder), .int(Int64(uid)), .text(MailSearchText.folded(text.text))]) else { return nil }
                }
                return true
            } ?? false
        }
    }

    func search(
        folder: String, query: String, shouldStop: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) -> (uidValidity: UInt32, uids: [UInt32])? {
        let needle = MailSearchText.folded(MailTextCleaner.clean(query))
        return withFileDroppedIfDamaged {
            guard !needle.isEmpty, openOrRecreateLocked(), ownerLocked() == currentOwner,
                  let validity = validityLocked(folder) else { return nil }
            var uids: [UInt32] = []
            let check = StopCheck(shouldStop)
            sqlite3_progress_handler(db, Self.stopCheckSteps, { context in
                guard let context else { return 0 }
                return Unmanaged<StopCheck>.fromOpaque(context).takeUnretainedValue().shouldStop() ? 1 : 0
            }, Unmanaged.passUnretained(check).toOpaque())
            defer { sqlite3_progress_handler(db, 0, nil, nil) }
            let found = withExtendedLifetime(check) {
                execute("SELECT uid FROM mail WHERE folder = ? AND instr(text, ?) > 0 ORDER BY uid DESC",
                        [.text(folder), .text(needle)], row: {
                    uids.append(UInt32(truncatingIfNeeded: sqlite3_column_int64($0, 0)))
                })
            }
            return found ? (validity, uids) : nil
        }
    }

    func close(thenRemove remove: () -> Void) {
        lock.withLock {
            sqlite3_close_v2(db)
            db = nil
            remove()
        }
    }

    private enum Value {
        case text(String)
        case int(Int64)
    }

    private final class StopCheck {
        let shouldStop: @Sendable () -> Bool
        init(_ shouldStop: @escaping @Sendable () -> Bool) { self.shouldStop = shouldStop }
    }

    private static let stopCheckSteps: Int32 = 1_000

    private static var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }

    private var currentOwner: String { account() ?? "" }

    private func withFileDroppedIfDamaged<T>(_ body: () -> T) -> T {
        lock.withLock {
            let result = body()
            if isDamaged {
                sqlite3_close_v2(db)
                db = nil
                isDamaged = false
                deleteFileLocked()
            }
            return result
        }
    }

    private static func isDamage(_ code: Int32) -> Bool {
        code & 0xFF == SQLITE_CORRUPT || code & 0xFF == SQLITE_NOTADB
    }

    private func openOrRecreateLocked() -> Bool {
        guard db == nil else { return true }
        let result = openOnceLocked()
        guard Self.isDamage(result) else { return result == SQLITE_OK }
        deleteFileLocked()
        isDamaged = false
        return openOnceLocked() == SQLITE_OK
    }

    private func deleteFileLocked() {
        AppLogger.persistence.error("Mail search index unreadable, starting over")
        for suffix in ["", "-journal", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    private func openOnceLocked() -> Int32 {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        MailCacheFiles.excludeFromBackup(directory)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FILEPROTECTION_COMPLETEUNTILFIRSTUSERAUTHENTICATION
        let opened = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard opened == SQLITE_OK else {
            AppLogger.persistence.error("Mail search index open failed: \(opened, privacy: .public)")
            sqlite3_close_v2(handle)
            return opened & 0xFF
        }
        db = handle
        guard resetIfSchemaChangedLocked() else {
            let code = sqlite3_errcode(handle) & 0xFF
            sqlite3_close_v2(handle)
            db = nil
            return code == SQLITE_OK ? SQLITE_ERROR : code
        }
        MailCacheFiles.excludeFromBackup(url)
        return SQLITE_OK
    }

    private func resetIfSchemaChangedLocked() -> Bool {
        var version: Int64 = 0
        guard execute("PRAGMA user_version", row: { version = sqlite3_column_int64($0, 0) }) else { return false }
        guard version != Self.schemaVersion else { return true }
        return sqlite3_exec(db, """
            DROP TABLE IF EXISTS owner; DROP TABLE IF EXISTS folders; DROP TABLE IF EXISTS mail;
            CREATE TABLE owner (id TEXT NOT NULL);
            CREATE TABLE folders (name TEXT PRIMARY KEY NOT NULL, uid_validity INTEGER NOT NULL);
            CREATE TABLE mail (folder TEXT NOT NULL, uid INTEGER NOT NULL, text TEXT NOT NULL,
                               PRIMARY KEY (folder, uid)) WITHOUT ROWID;
            PRAGMA user_version = \(Self.schemaVersion);
            """, nil, nil, nil) == SQLITE_OK
    }

    private func ownerLocked() -> String? {
        var owner: String?
        execute("SELECT id FROM owner", row: { owner = sqlite3_column_text($0, 0).map { String(cString: $0) } })
        return owner
    }

    private func adoptOwnerLocked() -> Bool {
        let owner = currentOwner
        guard ownerLocked() != owner else { return true }
        return execute("DELETE FROM mail") && execute("DELETE FROM folders") && execute("DELETE FROM owner")
            && execute("INSERT INTO owner (id) VALUES (?)", [.text(owner)])
    }

    private func validityLocked(_ folder: String) -> UInt32? {
        var validity: UInt32?
        execute("SELECT uid_validity FROM folders WHERE name = ?", [.text(folder)], row: {
            validity = UInt32(truncatingIfNeeded: sqlite3_column_int64($0, 0))
        })
        return validity
    }

    private func transactionLocked<T>(_ body: () -> T?) -> T? {
        guard execute("BEGIN IMMEDIATE") else { return nil }
        guard let result = body(), execute("COMMIT") else {
            execute("ROLLBACK")
            return nil
        }
        return result
    }

    @discardableResult
    private func execute(_ sql: String, _ values: [Value] = [], row: ((OpaquePointer) -> Void)? = nil) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            let code = sqlite3_errcode(db)
            AppLogger.persistence.error("Mail search index prepare failed: \(code, privacy: .public)")
            if Self.isDamage(code) { isDamaged = true }
            return false
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let position = Int32(offset + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, position, text, -1, Self.transient)
            case .int(let number): sqlite3_bind_int64(statement, position, number)
            }
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: row?(statement)
            case SQLITE_DONE: return true
            case SQLITE_INTERRUPT: return false
            case let code:
                AppLogger.persistence.error("Mail search index step failed: \(code, privacy: .public)")
                if Self.isDamage(code) { isDamaged = true }
                return false
            }
        }
    }
}
#endif
