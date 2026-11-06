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
    var moving: MailMessageViewModel?
    var deletingForever: MailMessageViewModel?
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
        case .move: moving = message(row, in: list)
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
        await once(model, in: list) {
            if await model.prepareDelete() {
                deletingForever = model
                return true
            }
            return await model.delete()
        }
    }

    func deleteForever(_ model: MailMessageViewModel, in list: MailListViewModel) async {
        await once(model, in: list) { await model.delete() }
    }

    func move(_ model: MailMessageViewModel, to folder: String, in list: MailListViewModel) async {
        await once(model, in: list) { await model.move(to: folder) }
    }

    func compose(_ mode: MailComposeMode, row: MailListRow, in list: MailListViewModel) async -> MailComposeContext? {
        let model = message(row, in: list)
        let signIn = await list.account.startingSignIn
        composing = mode
        defer { composing = nil }
        var context: MailComposeContext?
        await once(model, in: list) {
            await model.load()
            context = model.detail.map { _ in model.composeContext(mode) }
            return context != nil
        }
        return signIn.isCurrent ? context : nil
    }

    private func once(_ model: MailMessageViewModel, in list: MailListViewModel, _ work: () async -> Bool) async {
        let key = Work(row: MailListRow.ID(folder: model.route.folder, uid: model.route.uid), flag: nil)
        guard busy.insert(key).inserted else { return }
        defer { busy.remove(key) }
        let signIn = await list.account.startingSignIn
        let done = await work()
        guard !done, signIn.isCurrent else { return }
        if case .failed(let message) = model.loadState, model.detail == nil {
            list.status.actionError = message
        } else {
            list.status.actionError = model.actionError
        }
    }

    private struct Work: Hashable {
        let row: MailListRow.ID
        let flag: MailFlag?
    }
}
#endif
