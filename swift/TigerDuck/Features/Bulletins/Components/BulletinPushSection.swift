import SwiftUI
import UserNotifications

struct BulletinPushSection: View {
    let pushEnabled: Bool
    let authStatus: UNAuthorizationStatus
    let isAskingPermission: Bool
    let isDisablingPush: Bool
    let pushUpdateFailed: Bool
    let onEnable: () -> Void
    let onDisable: () -> Void
    var enableClosedReason: LocalizedStringResource?

    var body: some View {
        if pushEnabled {
            Section {
                LabeledContent {
                    Text(authStatusText)
                        .foregroundStyle(authStatusColor)
                        .font(.caption)
                } label: {
                    Label(String(localized: "bulletin_push_status_label"), systemImage: "bell.fill")
                }

                if authStatus == .denied {
                    Button {
                        openAppSettings()
                    } label: {
                        Label(String(localized: "bulletin_push_reopen_settings"), systemImage: "gear")
                    }
                }

                Button(role: .destructive) {
                    onDisable()
                } label: {
                    LoadingButtonLabel(isLoading: isDisablingPush) {
                        Label(String(localized: "bulletin_push_disable_action"), systemImage: "bell.slash")
                    }
                }
                .disabled(isDisablingPush)
            } header: {
                Text(String(localized: "bulletin_push_settings_header"))
            } footer: {
                if pushUpdateFailed {
                    Text(String(localized: "settings_server_push_update_failed"))
                        .foregroundStyle(.orange)
                }
            }
        } else {
            Section {
                VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs) {
                    Text(String(localized: "bulletin_push_enable_description"))
                        .font(.callout)
                        .foregroundStyle(.primary)
                    Text(String(localized: "bulletin_push_content_description"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    onEnable()
                } label: {
                    LoadingButtonLabel(isLoading: isAskingPermission) {
                        Label(String(localized: "bulletin_push_enable_action"), systemImage: "bell.badge")
                    }
                }
                .disabled(isAskingPermission)
                .disabled(because: enableClosedReason)

                if BulletinNotificationSettingsView.requiresSystemSettingsRoute(for: authStatus) {
                    Button {
                        openAppSettings()
                    } label: {
                        Label(String(localized: "bulletin_push_reopen_settings"), systemImage: "gear")
                    }
                }
            } header: {
                Text(String(localized: "bulletin_push_settings_header"))
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if BulletinNotificationSettingsView.requiresSystemSettingsRoute(for: authStatus) {
                        Text(String(localized: "permission_not_granted_tap_settings"))
                            .foregroundStyle(.orange)
                    }
                    Text(String(localized: "bulletin_push_footer"))
                    if pushUpdateFailed {
                        Text(String(localized: "settings_server_push_update_failed"))
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private var authStatusText: String {
        switch authStatus {
        case .authorized: return String(localized: "permission_granted")
        case .provisional: return String(localized: "bulletin_push_status_provisional")
        case .denied: return String(localized: "bulletin_push_status_denied")
        case .notDetermined: return String(localized: "bulletin_push_status_undetermined")
        case .ephemeral: return String(localized: "bulletin_push_status_ephemeral")
        @unknown default: return String(localized: "bulletin_push_status_unknown")
        }
    }

    private var authStatusColor: Color {
        switch authStatus {
        case .authorized, .provisional: return .green
        case .denied: return .red
        default: return .secondary
        }
    }
}
