#if os(iOS)
import Foundation

/// A folder's owned-`\Deleted` UIDs, always paired with the UIDVALIDITY generation they were
/// recorded under. Carrying folder and UIDVALIDITY as two independent parameters (as an earlier
/// version of this type did) made it possible to supply a UID set recorded under one
/// folder/generation while a freshly read, currently-matching UIDVALIDITY sailed straight past
/// the guard below — a stale owned set, paired with an unrelated but currently-valid check, is
/// exactly how another client's `\Deleted` mail could get swept into an EXPUNGE. Bundling both
/// into one value makes that mis-keying unrepresentable: whoever built this value is the same
/// one whose folder+validity get checked against the server before anything runs.
nonisolated struct OwnedDeleted: Sendable, Equatable {
    var folder: String
    var uidValidity: UInt32
    var uids: Set<UInt32>
}

nonisolated struct MailMoveResult: Equatable, Sendable {
    var expunged: Bool
    /// UIDs TigerDuck flagged `\Deleted` that are still waiting for a safe EXPUNGE, already keyed
    /// by the folder and UIDVALIDITY they belong to — persist this value as-is.
    var stillPending: OwnedDeleted
}

/// Move and delete without UIDPLUS (design doc §8.3). The server's only EXPUNGE removes
/// every `\Deleted` message in the folder — including ones another client flagged — so
/// TigerDuck expunges only when every `\Deleted` message is one it flagged itself, checked
/// fresh against the server (never against cached flags). Otherwise its own flags wait
/// (hidden from the list) for a later, safe EXPUNGE.
///
/// Before touching anything, both operations confirm the folder's UIDVALIDITY still matches
/// what `previouslyFlagged` was recorded under — if the folder was recreated server-side, every
/// UID in it now means something different, so COPY/STORE never run; the caller must refresh
/// and retry. A `uids` argument of `[]` also runs no server command at all, and returns
/// `previouslyFlagged` unchanged.
///
/// Neither operation retries a command that may already have started on the server (COPY,
/// STORE, EXPUNGE): a throw after that point is reported as-is, and `recoverAfterFailure`
/// lets the caller find out, with a single fresh read, whether the flag actually took.
///
/// This still cannot close every race: another client can flag or expunge mail server-side in
/// the gap between the deleted-UID check below and the EXPUNGE that immediately follows it.
/// Real Mail2000 has no UIDPLUS, so there is no atomic "expunge exactly these UIDs" primitive
/// to close that window with — COPY + STORE + a fresh server-side check right before EXPUNGE is
/// the narrowest window achievable here.
nonisolated enum MailMover {
    static func move(
        uids: [UInt32], from folder: String, to target: String,
        client: any MailClient, previouslyFlagged: OwnedDeleted
    ) async throws -> MailMoveResult {
        guard !uids.isEmpty else { return MailMoveResult(expunged: false, stillPending: previouslyFlagged) }
        try await assertFolderUnchanged(folder: folder, previouslyFlagged: previouslyFlagged, client: client)
        try await client.copy(folder: folder, uids: uids, to: target)
        return try await flagAndMaybeExpunge(uids: uids, in: folder, client: client, previouslyFlagged: previouslyFlagged)
    }

    /// Permanent delete — the caller confirms with the user first (only offered in 回收筒).
    static func deletePermanently(
        uids: [UInt32], in folder: String,
        client: any MailClient, previouslyFlagged: OwnedDeleted
    ) async throws -> MailMoveResult {
        guard !uids.isEmpty else { return MailMoveResult(expunged: false, stillPending: previouslyFlagged) }
        try await assertFolderUnchanged(folder: folder, previouslyFlagged: previouslyFlagged, client: client)
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
    ///
    /// Never call this after a `MailClientError.authenticationFailed` or `.certificateRejected`
    /// from the same operation: the credentials or connection that just failed are exactly what a
    /// fresh `flags` read would need, so this would only trigger a second, doomed request/login
    /// attempt against a server that already rejected them. (Android's equivalent, `runExpunging`,
    /// skips this same probe for those same two error cases.)
    static func recoverAfterFailure(
        uid: UInt32, folder: String, client: any MailClient, wasAlreadyDeleted: Bool
    ) async -> Bool {
        guard let flags = try? await client.flags(folder: folder, uids: uid...uid)[uid] else { return false }
        return shouldRecordAfterFailure(serverConfirmsDeleted: flags.deleted, wasAlreadyDeleted: wasAlreadyDeleted)
    }

    /// Reads UIDVALIDITY fresh on the caller's connection and refuses before COPY/STORE run if
    /// either the folder or the UIDVALIDITY `previouslyFlagged` was recorded under no longer
    /// matches. Checking the folder first (a local, no-network comparison) catches a
    /// mis-keyed/wrong-folder owned set without even asking the server.
    private static func assertFolderUnchanged(
        folder: String, previouslyFlagged: OwnedDeleted, client: any MailClient
    ) async throws {
        guard previouslyFlagged.folder == folder else { throw MailClientError.folderChanged }
        let status = try await client.status(folder: folder)
        guard status.uidValidity == previouslyFlagged.uidValidity else { throw MailClientError.folderChanged }
    }

    private static func flagAndMaybeExpunge(
        uids: [UInt32], in folder: String,
        client: any MailClient, previouslyFlagged: OwnedDeleted
    ) async throws -> MailMoveResult {
        try await client.setFlag(.deleted, on: true, folder: folder, uids: uids)
        let ours = previouslyFlagged.uids.union(uids)
        let deleted = try await client.deletedUIDs(folder: folder)
        guard shouldExpunge(deleted: deleted, ours: ours) else {
            return MailMoveResult(
                expunged: false,
                stillPending: OwnedDeleted(folder: folder, uidValidity: previouslyFlagged.uidValidity, uids: ours.intersection(deleted))
            )
        }
        try await client.expunge(folder: folder)
        return MailMoveResult(expunged: true, stillPending: OwnedDeleted(folder: folder, uidValidity: previouslyFlagged.uidValidity, uids: []))
    }
}
#endif
