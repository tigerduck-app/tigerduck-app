#if os(iOS)
import Foundation

@MainActor
enum MailComposeSending {
    struct ReplacedDraft {
        var uid: UInt32
        var pageUIDValidity: UInt32?
        var wasAlreadyDeleted: Bool
    }

    struct Send {
        var message: Data
        var messageID: String
        var from: String
        var recipients: [String]
        var roles: [MailFolderRole: String]
        var answered: (folder: String, uid: UInt32)?
        var replaced: (folder: String, draft: ReplacedDraft)?
    }

    static func send(_ send: Send, session: MailPageSession, services: MailComposeServices) async throws -> SentCopyFiler.Filing {
        try await session.use { client -> SentCopyFiler.Filing in
            try await client.send(send.message, from: send.from, to: send.recipients)
            if let answered = send.answered {
                try? await client.setFlag(.answered, on: true, folder: answered.folder, uids: [answered.uid], expectedUIDValidity: nil)
            }
            let filing = await SentCopyFiler.file(send.message, messageID: send.messageID, in: send.roles, client: client,
                                                  dedupeDelay: MailConstants.sentCopyDedupeDelay, sleep: services.sleep)
            if let replaced = send.replaced {
                await removeDraft(replaced.draft, folder: replaced.folder, client: client, prefs: services.prefs)
            }
            return filing
        }
    }

    static func saveDraft(
        _ message: Data, roles: [MailFolderRole: String], replacing draft: ReplacedDraft?,
        session: MailPageSession, prefs: any MailPreferences
    ) async throws -> [MailFolderRole: String] {
        try await session.use { client -> [MailFolderRole: String] in
            guard let drafts = await MailFolderProvisioner.ensure(.drafts, in: roles, client: client) else {
                throw MailFolderUnavailable(role: .drafts)
            }
            try await client.append(message, to: drafts.name, flags: [.draft, .seen])
            if let draft { await removeDraft(draft, folder: drafts.name, client: client, prefs: prefs) }
            return drafts.roles
        }
    }

    static func notice(for outcome: SentCopy) -> String? {
        switch outcome {
        case .filed, .serverFiledItself:
            nil
        case .notAttempted:
            String(localized: "school_mail_sent_copy_no_folder")
        case .failed(let error):
            String(localized: "school_mail_sent_copy_failed") + "\n" + MailAccountManager.LoginError(error).message
        case .unknown:
            String(localized: "school_mail_sent_copy_unknown")
        }
    }

    private static func removeDraft(_ draft: ReplacedDraft, folder: String, client: any MailClient, prefs: any MailPreferences) async {
        guard let pageUIDValidity = draft.pageUIDValidity else { return }
        let owned = prefs.ownedDeleted(folder: folder, uidValidity: pageUIDValidity)
        do {
            let result = try await MailMover.deletePermanently(uids: [draft.uid], in: folder, client: client, previouslyFlagged: owned)
            prefs.setOwnedDeleted(result.stillPending)
        } catch {
            guard let claim = await MailMover.recoverAfterFailure(after: error, uid: draft.uid, previouslyFlagged: owned,
                                                                  client: client, wasAlreadyDeleted: draft.wasAlreadyDeleted) else {
                return
            }
            prefs.setOwnedDeleted(claim)
        }
    }
}
#endif
