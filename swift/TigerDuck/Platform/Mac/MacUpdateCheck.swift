#if os(macOS)
import SwiftUI

/// The Mac's side of `UpdateNotifyCoordinator`: an alert when the App Store
/// has a newer version, and TigerDuck ▸ Check for Updates….
///
/// An alert rather than the iPhone's sheet: Update / Later / Skip is the
/// Mac's own update-alert shape, and the choice needs no more room than the
/// version number. The same alert answers a manual check with "up to date"
/// or "couldn't reach the App Store".
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
                    // Runs after a button's own action, and alone when the
                    // alert goes away without one. Clearing without the
                    // Later stamp leaves the next throttled check free to
                    // offer the version again, as on the iPhone.
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

/// What the alert says: an update on offer, or a manual check's answer when
/// there is none. An offer wins, so a manual check that finds one shows
/// that rather than its own result.
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

/// TigerDuck ▸ Check for Updates… — the manual check, which skips the daily
/// throttle and the Later / Skip memory. Its answer comes back through
/// `macUpdatePrompt()`.
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
    /// Mount the Mac update alert. Apply once, at the root of the main
    /// window — applied per screen it would stack one alert per view.
    func macUpdatePrompt() -> some View {
        modifier(MacUpdatePrompt())
    }
}
#endif
