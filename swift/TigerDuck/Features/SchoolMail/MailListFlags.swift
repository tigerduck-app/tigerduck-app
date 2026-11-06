#if os(iOS)
import Foundation

@MainActor
enum MailListFlags {
    static func toggle(_ flag: MailFlag, of row: MailListRow, list: MailListViewModel) async {
        let on = flag == .flagged ? !row.summary.isFlagged : !row.summary.isSeen
        await store(flag, on: on, folder: row.folder, uids: [row.uid], list: list)
    }

    static func markAllRead(for signIn: SignIn, list: MailListViewModel) async {
        let unread = Dictionary(grouping: list.displayedRows.filter { !$0.summary.isSeen }, by: \.folder)
        for (folder, rows) in unread where signIn.isCurrent {
            await store(.seen, on: true, folder: folder, uids: rows.map(\.uid), for: signIn, list: list)
        }
    }

    private static func store(
        _ flag: MailFlag, on: Bool, folder: String, uids: [UInt32], for given: SignIn? = nil, list: MailListViewModel
    ) async {
        mark(edit(flag, on), folder: folder, uids: uids, list: list)
        let validity = list.mailbox[folder]?.uidValidity
        let signIn = if let given { given } else { await list.account.startingSignIn }
        do {
            try await list.session.use(for: signIn) { client in
                try await client.setFlag(flag, on: on, folder: folder, uids: uids, expectedUIDValidity: validity)
            }
        } catch where !signIn.isCurrent {
        } catch MailClientError.folderChanged {
            mark(edit(flag, !on), folder: folder, uids: uids, list: list)
            await list.recoverFromFolderChange(folder)
        } catch {
            mark(edit(flag, !on), folder: folder, uids: uids, list: list)
            list.status.actionError = MailAccountManager.LoginError(error).message
        }
    }

    private static func edit(_ flag: MailFlag, _ on: Bool) -> MailboxPages.Edit {
        flag == .flagged ? .flagged(on) : .seen(on)
    }

    static func mark(_ edit: MailboxPages.Edit, folder: String, uids: [UInt32], list: MailListViewModel) {
        guard list.targets.contains(folder) else { return }
        for uid in uids {
            list.mailbox.mark(edit, folder: folder, uid: uid)
            list.search.mark(edit, folder: folder, uid: uid)
        }
        list.rebuildRows()
        if let page = list.mailbox[folder] { list.writer.save(page) }
    }
}
#endif
