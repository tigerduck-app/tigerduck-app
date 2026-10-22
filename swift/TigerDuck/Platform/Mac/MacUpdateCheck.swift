#if os(macOS)
import SwiftUI

private struct MacUpdatePrompt: ViewModifier {
    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        let coordinator = appState.updateNotifyCoordinator
        let notice = MacUpdateNotice(coordinator: coordinator)
        return content.alert(
            notice?.title ?? "",
            isPresented: Binding(
                get: { notice != nil },
                set: { presented in
                    guard !presented else { return }
                    coordinator.pendingUpdate = nil
                    coordinator.lastManualCheckResult = nil
                }
            ),
            presenting: notice
        ) { notice in
            switch notice {
            case .update:
                Button(String(localized: "update_action_update_now")) {
                    coordinator.handleUpdatePromptAction(.updateNow)
                }
                Button(String(localized: "update_action_later"), role: .cancel) {
                    coordinator.handleUpdatePromptAction(.later)
                }
                Button(String(localized: "update_action_skip_version")) {
                    coordinator.handleUpdatePromptAction(.skipThisVersion)
                }
            case .upToDate, .failed:
                Button(String(localized: "action_got_it"), role: .cancel) {}
            }
        } message: { notice in
            Text(notice.message)
        }
    }
}

private enum MacUpdateNotice {
    case update(UpdateNotifyCoordinator.PendingUpdate)
    case upToDate
    case failed

    @MainActor
    init?(coordinator: UpdateNotifyCoordinator) {
        if let pending = coordinator.pendingUpdate {
            self = .update(pending)
            return
        }
        switch coordinator.lastManualCheckResult {
        case .upToDate: self = .upToDate
        case .failed: self = .failed
        case .offered, nil: return nil
        }
    }

    var title: String {
        switch self {
        case .update: String(localized: "update_available_title")
        case .upToDate: String(localized: "update_up_to_date_title")
        case .failed: String(localized: "update_check_failed_title")
        }
    }

    var message: String {
        switch self {
        case .update(let pending):
            String(format: NSLocalizedString("update_available_message", comment: ""), pending.latestVersion)
        case .upToDate:
            String(format: NSLocalizedString("update_up_to_date_message", comment: ""), AppConstants.appName)
        case .failed:
            String(localized: "update_check_failed_message")
        }
    }
}

struct MacCheckForUpdatesCommand: View {
    let coordinator: UpdateNotifyCoordinator

    var body: some View {
        Button(String(localized: "settings_check_for_updates") + "…") {
            Task { await coordinator.checkManually() }
        }
        .disabled(coordinator.isCheckingForUpdate)
    }
}

extension View {
    func macUpdatePrompt() -> some View {
        modifier(MacUpdatePrompt())
    }
}
#endif
