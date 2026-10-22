#if os(iOS)
import Foundation

nonisolated struct OwnedDeleted: Sendable, Equatable {
    var folder: String
    var uidValidity: UInt32
    var uids: Set<UInt32>
}

nonisolated struct MailMoveResult: Equatable, Sendable {
    var expunged: Bool
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

    static func shouldRecordAfterFailure(serverConfirmsDeleted: Bool, wasAlreadyDeleted: Bool) -> Bool {
        serverConfirmsDeleted && !wasAlreadyDeleted
    }

    static func shouldProbeAfterFailure(_ error: any Error) -> Bool {
        switch error as? MailClientError {
        case .authenticationFailed, .certificateRejected, .folderChanged: false
        default: true
        }
    }

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
