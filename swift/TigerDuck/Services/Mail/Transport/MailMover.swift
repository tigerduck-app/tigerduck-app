#if os(iOS)
import Foundation

nonisolated struct MailMoveResult: Equatable, Sendable {
    var expunged: Bool
    /// UIDs TigerDuck flagged `\Deleted` that are still waiting for a safe EXPUNGE.
    var stillPending: Set<UInt32>
}

/// Move and delete without UIDPLUS (design doc §8.3). The server's only EXPUNGE removes
/// every `\Deleted` message in the folder — including ones another client flagged — so
/// TigerDuck expunges only when every `\Deleted` message is one it flagged itself, checked
/// fresh against the server (never against cached flags). Otherwise its own flags wait
/// (hidden from the list) for a later, safe EXPUNGE.
///
/// Before touching anything, both operations confirm the folder's UIDVALIDITY still matches
/// what the caller's list was built from — if the folder was recreated server-side, every UID
/// in it now means something different, so COPY/STORE never run; the caller must refresh and
/// retry. Neither operation retries a command that may already have started on the server
/// (COPY, STORE, EXPUNGE): a throw after that point is reported as-is, and `recoverAfterFailure`
/// lets the caller find out, with a single fresh read, whether the flag actually took.
nonisolated enum MailMover {
    static func move(
        uids: [UInt32], from folder: String, to target: String,
        client: any MailClient, previouslyFlagged: Set<UInt32>, expectedUIDValidity: UInt32
    ) async throws -> MailMoveResult {
        try await assertFolderUnchanged(folder: folder, expectedUIDValidity: expectedUIDValidity, client: client)
        try await client.copy(folder: folder, uids: uids, to: target)
        return try await flagAndMaybeExpunge(uids: uids, in: folder, client: client, previouslyFlagged: previouslyFlagged)
    }

    /// Permanent delete — the caller confirms with the user first (only offered in 回收筒).
    static func deletePermanently(
        uids: [UInt32], in folder: String,
        client: any MailClient, previouslyFlagged: Set<UInt32>, expectedUIDValidity: UInt32
    ) async throws -> MailMoveResult {
        try await assertFolderUnchanged(folder: folder, expectedUIDValidity: expectedUIDValidity, client: client)
        return try await flagAndMaybeExpunge(uids: uids, in: folder, client: client, previouslyFlagged: previouslyFlagged)
    }

    static func shouldExpunge(deleted: Set<UInt32>, ours: Set<UInt32>) -> Bool {
        !deleted.isEmpty && deleted.isSubset(of: ours)
    }

    /// Whether a UID flagged `\Deleted` right before `move`/`deletePermanently` threw should be
    /// remembered as ours for a later, safe EXPUNGE to reclaim. True only when the server
    /// confirms the flag actually landed, and only when the caller's own cached copy was not
    /// already `\Deleted` before this call — a message someone else already deleted must never
    /// become "ours" just because our own STORE also touched it, or a later EXPUNGE could remove
    /// mail that isn't ours to remove.
    static func shouldRecordAfterFailure(serverConfirmsDeleted: Bool, wasAlreadyDeleted: Bool) -> Bool {
        serverConfirmsDeleted && !wasAlreadyDeleted
    }

    /// Call from a `catch` around `move`/`deletePermanently`: a COPY + STORE may have partly
    /// landed on the server before the throw. Never retries the failed command itself — asks the
    /// server, once, whether the `\Deleted` flag actually took, and applies `shouldRecordAfterFailure`.
    /// Returns `false` (nothing to record) if that check itself fails.
    static func recoverAfterFailure(
        uid: UInt32, folder: String, client: any MailClient, wasAlreadyDeleted: Bool
    ) async -> Bool {
        guard let flags = try? await client.flags(folder: folder, uids: uid...uid)[uid] else { return false }
        return shouldRecordAfterFailure(serverConfirmsDeleted: flags.deleted, wasAlreadyDeleted: wasAlreadyDeleted)
    }

    /// Reads UIDVALIDITY fresh on the caller's connection and refuses before COPY/STORE run if it
    /// no longer matches the value the caller's list came from.
    private static func assertFolderUnchanged(
        folder: String, expectedUIDValidity: UInt32, client: any MailClient
    ) async throws {
        let status = try await client.status(folder: folder)
        guard status.uidValidity == expectedUIDValidity else { throw MailClientError.folderChanged }
    }

    private static func flagAndMaybeExpunge(
        uids: [UInt32], in folder: String,
        client: any MailClient, previouslyFlagged: Set<UInt32>
    ) async throws -> MailMoveResult {
        try await client.setFlag(.deleted, on: true, folder: folder, uids: uids)
        let ours = previouslyFlagged.union(uids)
        let deleted = try await client.deletedUIDs(folder: folder)
        guard shouldExpunge(deleted: deleted, ours: ours) else {
            return MailMoveResult(expunged: false, stillPending: ours.intersection(deleted))
        }
        try await client.expunge(folder: folder)
        return MailMoveResult(expunged: true, stillPending: [])
    }
}
#endif
