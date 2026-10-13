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

/// Move and delete without UIDPLUS. EXPUNGE removes every `\Deleted` message in the folder,
/// another client's included, so TigerDuck expunges only when every one is its own, checked fresh
/// on the server; otherwise its flags wait, hidden from the list. Each step that changes mail
/// carries `previouslyFlagged.uidValidity` to check against its own SELECT, since the 60 s poll
/// can run between steps. A recreated folder means `.folderChanged`, which no caller retries.
/// Started commands are never retried (`recoverAfterFailure` asks the server once). Another
/// client can still act between the deleted-UID check and EXPUNGE.
/// See docs/decisions/0014-mail-delete-without-uidplus.md.
nonisolated enum MailMover {
    static func move(
        uids: [UInt32], from folder: String, to target: String,
        client: any MailClient, previouslyFlagged: OwnedDeleted
    ) async throws -> MailMoveResult {
        guard !uids.isEmpty else { return MailMoveResult(expunged: false, stillPending: previouslyFlagged) }
        try await assertFolderUnchanged(folder: folder, previouslyFlagged: previouslyFlagged, client: client)
        try await client.copy(folder: folder, uids: uids, to: target, expectedUIDValidity: previouslyFlagged.uidValidity)
        return try await flagAndMaybeExpunge(uids: uids, in: folder, client: client, previouslyFlagged: previouslyFlagged)
    }

    /// Permanent delete — the caller confirms with the user first (only offered in Trash).
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

    /// Whether a failed `move`/`deletePermanently` is worth asking the server about at all.
    ///
    /// The credentials or the connection that just failed are exactly what a fresh `flags` read
    /// would need, so probing after an authentication rejection or a certificate failure would
    /// only fire a second, doomed request against a server that already refused — and after a
    /// `folderChanged` there is nothing to attribute, since the pin the probe would be read under
    /// no longer describes the folder. (Android's equivalent, `runExpunging`, skips the same
    /// probe for the same reasons.)
    static func shouldProbeAfterFailure(_ error: any Error) -> Bool {
        switch error as? MailClientError {
        case .authenticationFailed, .certificateRejected, .folderChanged: false
        default: true
        }
    }

    /// Call from a `catch` around `move`/`deletePermanently`. A COPY + STORE may have partly
    /// landed before the throw, and a `\Deleted` UID this app flagged but does not claim keeps
    /// `shouldExpunge` false in that folder for good: later deletes there only hide, and Trash
    /// deletes nothing. Never retries the failed command; asks the server once whether the flag
    /// took and applies `shouldRecordAfterFailure`. Returns the record to persist, or `nil` when
    /// there is nothing to claim, including a skipped (`shouldProbeAfterFailure`) or failed probe.
    /// The probe carries `previouslyFlagged.uidValidity`, so a folder recreated in between never
    /// has one of its messages attributed to TigerDuck.
    static func recoverAfterFailure(
        after error: any Error, uid: UInt32, previouslyFlagged: OwnedDeleted,
        client: any MailClient, wasAlreadyDeleted: Bool
    ) async -> OwnedDeleted? {
        guard shouldProbeAfterFailure(error) else { return nil }
        guard let flags = try? await client.flags(folder: previouslyFlagged.folder, uids: uid...uid,
                                                  expectedUIDValidity: previouslyFlagged.uidValidity)[uid] else {
            return nil
        }
        guard shouldRecordAfterFailure(serverConfirmsDeleted: flags.deleted, wasAlreadyDeleted: wasAlreadyDeleted) else {
            return nil
        }
        return OwnedDeleted(folder: previouslyFlagged.folder, uidValidity: previouslyFlagged.uidValidity,
                            uids: previouslyFlagged.uids.union([uid]))
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
        let pin = previouslyFlagged.uidValidity
        try await client.setFlag(.deleted, on: true, folder: folder, uids: uids, expectedUIDValidity: pin)
        let ours = previouslyFlagged.uids.union(uids)
        let deleted = try await client.deletedUIDs(folder: folder, expectedUIDValidity: pin)
        guard shouldExpunge(deleted: deleted, ours: ours) else {
            return MailMoveResult(
                expunged: false,
                stillPending: OwnedDeleted(folder: folder, uidValidity: previouslyFlagged.uidValidity, uids: ours.intersection(deleted))
            )
        }
        try await client.expunge(folder: folder, expectedUIDValidity: pin)
        return MailMoveResult(expunged: true, stillPending: OwnedDeleted(folder: folder, uidValidity: pin, uids: []))
    }
}
#endif
