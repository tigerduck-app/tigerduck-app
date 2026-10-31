import Defaults
import SwiftUI

/// Where a link, a notification tap or a widget sends the user, held until the view that shows
/// it reads and clears it.
@MainActor
@Observable
final class AppRouter {
    var isShowingNTUSTLoginSheet = false
    var pendingWidgetDestination: WidgetDestination?
    var pendingMoreDeepLink: AppFeature?
    #if os(iOS)
    var pendingDeepLink: DeepLink?
    var pendingServerPopup: ServerPopupPayload?
    @ObservationIgnored private var serverPopupSwap: Task<Void, Never>?
    #endif

    func presentNTUSTLogin() {
        guard !isShowingNTUSTLoginSheet else { return }
        isShowingNTUSTLoginSheet = true
    }

    func dismissNTUSTLogin() {
        isShowingNTUSTLoginSheet = false
    }

    func openFromWidget(_ destination: WidgetDestination) {
        pendingWidgetDestination = destination
    }

    func clearPendingWidgetDestination() {
        pendingWidgetDestination = nil
    }

    /// A class table share link, a widget's link, or on iPhone a Live Activity's assignment link.
    func open(_ url: URL, signIn: AccountSession.Ticket) {
        if let text = ClassTableShareLink.codeText(url) {
            HeldShareLink.shared.arrived(text, signIn: signIn)
            openFromWidget(.classTable)
            return
        }
        #if os(iOS)
        if let id = WidgetURLRouter.assignmentId(from: url) {
            pendingDeepLink = .assignment(id)
            return
        }
        #endif
        guard let destination = WidgetURLRouter.route(url) else { return }
        openFromWidget(destination)
    }

    #if os(iOS)
    func openNotification(_ info: [AnyHashable: Any], assignments: () -> [SDAssignment]) {
        switch info["kind"] as? String {
        case "custom_push_bulletin", "bulletin":
            if let link = DeepLink.bulletinLink(from: info) {
                pendingDeepLink = link
            }
        case "assignment_reminder":
            if let assignment = DeepLink.remindedAssignment(from: info, in: assignments()) {
                pendingDeepLink = .assignment(assignment.assignmentId)
            }
        case "custom_push_popup":
            guard let nid = info["notification_id"] as? String,
                  let title = info["title"] as? String,
                  let body = info["body"] as? String,
                  !isServerPopupShown(nid) else { return }
            showServerPopup(ServerPopupPayload(id: nid, title: title, body: body))
        case MailConstants.notificationKind:
            pendingDeepLink = DeepLink.schoolMailLink(from: info)
        default:
            break
        }
    }

    /// A popup arriving over a shown one clears it and shows a tick later, so
    /// `.alert(_:isPresented:presenting:)` sees `isPresented` go from false to true.
    private func showServerPopup(_ payload: ServerPopupPayload) {
        serverPopupSwap?.cancel()
        serverPopupSwap = nil
        guard pendingServerPopup != nil else {
            pendingServerPopup = payload
            return
        }
        pendingServerPopup = nil
        serverPopupSwap = Task { @MainActor [weak self] in
            try? await AppClock.sleep(until: ContinuousClock.now + .milliseconds(50))
            guard !Task.isCancelled, let self else { return }
            pendingServerPopup = payload
            serverPopupSwap = nil
        }
    }

    func isServerPopupShown(_ id: String) -> Bool {
        Defaults[.shownServerPopupIds].contains(id)
    }

    func markServerPopupShown(_ id: String) {
        var seen = Defaults[.shownServerPopupIds]
        if seen.contains(id) { return }
        seen.append(id)
        if seen.count > 100 {
            seen.removeFirst(seen.count - 100)
        }
        Defaults[.shownServerPopupIds] = seen
    }
    #endif
}
