#if os(iOS)
import Foundation
import Observation

nonisolated enum MailRowAction: Hashable {
    case compose(MailComposeMode), toggleRead, toggleFlag, move, trash, more

    static let composeModes: [MailComposeMode] = [.reply, .replyAll, .forward]

    /// SwiftUI draws the first trailing action at the edge and runs it on a full swipe.
    static func trailing(canFlag: Bool) -> [MailRowAction] {
        canFlag ? [.trash, .toggleFlag, .more] : [.trash, .more]
    }

    func title(for summary: MailSummary?) -> String {
        switch self {
        case .compose(.replyAll): String(localized: "school_mail_reply_all")
        case .compose(.forward): String(localized: "school_mail_forward")
        case .compose: String(localized: "school_mail_reply")
        case .toggleRead: (summary?.isSeen ?? true) ? String(localized: "school_mail_mark_unread") : String(localized: "school_mail_mark_read")
        case .toggleFlag: summary?.isFlagged == true ? String(localized: "school_mail_unflag") : String(localized: "school_mail_flag")
        case .move: String(localized: "school_mail_move_to")
        case .trash: String(localized: "school_mail_delete")
        case .more: String(localized: "school_mail_message_actions")
        }
    }

    func icon(for summary: MailSummary?) -> String {
        switch self {
        case .compose(.replyAll): "arrowshape.turn.up.left.2"
        case .compose(.forward): "arrowshape.turn.up.right"
        case .compose: "arrowshape.turn.up.left"
        case .toggleRead: (summary?.isSeen ?? true) ? "envelope.badge" : "envelope.open"
        case .toggleFlag: summary?.isFlagged == true ? "flag.slash" : "flag"
        case .move: "folder"
        case .trash: "trash"
        case .more: "ellipsis.circle"
        }
    }
}

@MainActor
@Observable
final class MailRowActions {
    var sheetRow: MailListRow?
    var composing: MailComposeMode?
    var moving: PendingMessage?
    var deletingForever: PendingMessage?
    @ObservationIgnored var afterSheet: (() -> Void)?
    @ObservationIgnored private var busy: Set<Work> = []
    @ObservationIgnored private let prefs: (any MailPreferences)?
    @ObservationIgnored private let notifier: MailNotifier?

    init(prefs: (any MailPreferences)? = nil, notifier: MailNotifier? = nil) {
        self.prefs = prefs
        self.notifier = notifier
    }

    func perform(_ action: MailRowAction, on row: MailListRow, in list: MailListViewModel) {
        switch action {
        case .toggleRead: Task { await toggle(.seen, row, in: list) }
        case .toggleFlag: Task { await toggle(.flagged, row, in: list) }
        case .trash: Task { await trash(row, in: list) }
        case .move: moving = PendingMessage(model: message(row, in: list), signIn: list.account.currentSignIn)
        case .more: sheetRow = row
        case .compose: break
        }
    }

    func message(_ row: MailListRow, in list: MailListViewModel) -> MailMessageViewModel {
        let route = MailMessageRoute(folder: row.folder, uid: row.uid, uidValidity: list.mailbox[row.folder]?.uidValidity)
        return MailMessageViewModel(route: route, session: list.session, folderRoles: list.folderRoles, events: list.events,
                                    cache: list.writer.cache, prefs: prefs, notifier: notifier ?? MailChecker.shared.notifier)
    }

    func toggle(_ flag: MailFlag, _ row: MailListRow, in list: MailListViewModel) async {
        let key = Work(row: row.id, flag: flag)
        guard busy.insert(key).inserted else { return }
        defer { busy.remove(key) }
        await MailListFlags.toggle(flag, of: row, list: list)
    }

    func trash(_ row: MailListRow, in list: MailListViewModel) async {
        let model = message(row, in: list)
        let signIn = await list.account.startingSignIn
        await once(model, for: signIn, in: list) {
            let permanent = await MailMessageActions.prepareDelete(model: model, for: signIn)
            guard signIn.isCurrent else { return false }
            guard permanent else { return await MailMessageActions.delete(model: model, for: signIn) }
            deletingForever = PendingMessage(model: model, signIn: signIn)
            return true
        }
    }

    func deleteForever(_ pending: PendingMessage, in list: MailListViewModel) async {
        await once(pending.model, for: pending.signIn, in: list) {
            await MailMessageActions.delete(model: pending.model, for: pending.signIn)
        }
    }

    func move(_ pending: PendingMessage, to folder: String, in list: MailListViewModel) async {
        await once(pending.model, for: pending.signIn, in: list) {
            await MailMessageActions.move(model: pending.model, to: folder, for: pending.signIn)
        }
    }

    func compose(_ mode: MailComposeMode, row: MailListRow, in list: MailListViewModel) async -> MailComposeContext? {
        let model = message(row, in: list)
        let signIn = await list.account.startingSignIn
        composing = mode
        defer { composing = nil }
        var context: MailComposeContext?
        await once(model, for: signIn, in: list) {
            await model.load()
            context = model.detail.map { _ in model.composeContext(mode) }
            return context != nil
        }
        return signIn.isCurrent ? context : nil
    }

    private func once(
        _ model: MailMessageViewModel, for signIn: SignIn, in list: MailListViewModel, _ work: () async -> Bool
    ) async {
        let key = Work(row: MailListRow.ID(folder: model.route.folder, uid: model.route.uid), flag: nil)
        guard busy.insert(key).inserted else { return }
        defer { busy.remove(key) }
        let done = await work()
        guard !done, signIn.isCurrent else { return }
        if case .failed(let message) = model.loadState, model.detail == nil {
            list.status.actionError = message
        } else {
            list.status.actionError = model.actionError
        }
    }

    struct PendingMessage: Identifiable {
        let model: MailMessageViewModel
        let signIn: SignIn
        var id: ObjectIdentifier { model.id }
    }

    private struct Work: Hashable {
        let row: MailListRow.ID
        let flag: MailFlag?
    }
}
#endif
