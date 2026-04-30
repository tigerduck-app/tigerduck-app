import Defaults
import SwiftUI
import UserNotifications

/// Settings page for the push notification server.
///
/// The status section stays so users (and us in support) can see at a
/// glance whether the pipeline is healthy. The raw server URL and the
/// debug override field are intentionally not shown — users don't need
/// them, and exposing them makes the screen feel like a dev console.
struct PushServerSettingsView: View {
    @Environment(AppState.self) private var appState
    @Default(.pushServerEnabled) private var pushServerEnabled
    @Default(.pushLastRegistrationAt) private var lastRegistrationAt
    @Default(.pushLastSyncAt) private var lastSyncAt

    @State private var snapshot: PushDiagnostic?
    @State private var refreshTimer: Timer?
    @State private var disableTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "push_server_enable_toggle"), isOn: toggleBinding)
            } footer: {
                Text(String(localized: "push_server_footer"))
            }

            if pushServerEnabled, let s = snapshot {
                Section(String(localized: "push_server_status_section")) {
                    statusRow(label: String(localized: "push_server_status_live_activities"),
                              ok: s.liveActivitiesEnabled,
                              okText: String(localized: "push_server_status_enabled"),
                              badText: String(localized: "push_server_status_settings_hint"))
                    statusRow(label: String(localized: "permission_notifications_name"),
                              ok: s.notificationAuthStatus == .authorized || s.notificationAuthStatus == .provisional,
                              okText: notificationStatusText(s.notificationAuthStatus),
                              badText: notificationStatusText(s.notificationAuthStatus))
                    statusRow(label: String(localized: "push_server_status_device_registration"),
                              ok: s.registration.ptsTokenLength > 0,
                              okText: String(localized: "push_server_status_done"),
                              badText: String(localized: "push_server_status_waiting_token"))
                    LabeledContent(String(localized: "push_server_last_registration")) {
                        if let at = lastRegistrationAt {
                            Text(at, style: .relative).foregroundStyle(.secondary).monospacedDigit()
                        } else {
                            Text(String(localized: "push_server_pending_incomplete")).foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent(String(localized: "push_server_last_sync")) {
                        if let at = lastSyncAt {
                            Text(at, style: .relative).foregroundStyle(.secondary).monospacedDigit()
                        } else {
                            Text(String(localized: "push_server_pending_incomplete")).foregroundStyle(.secondary)
                        }
                    }
                    if let err = s.registration.lastError {
                        LabeledContent(String(localized: "push_server_latest_error")) {
                            Text(err).font(.caption).foregroundStyle(.red)
                        }
                    }
                    Button(String(localized: "push_server_sync_now_action")) { appState.requestPushScheduleSync() }
                }
            }
        }
        .navigationTitle(String(localized: "push_server_settings_title"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshSnapshot() }
        .onAppear {
            refreshTimer?.invalidate()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                Task { await refreshSnapshot() }
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { pushServerEnabled },
            set: { newValue in
                if newValue {
                    appState.enablePushServer()
                } else {
                    disableTask?.cancel()
                    disableTask = Task { await appState.disablePushServer() }
                }
                Task { await refreshSnapshot() }
            }
        )
    }

    private func refreshSnapshot() async {
        snapshot = await appState.pushCoordinator.currentSnapshot()
    }

    @ViewBuilder
    private func statusRow(label: String, ok: Bool, okText: String, badText: String) -> some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(ok ? .green : .orange)
                Text(ok ? okText : badText)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }

    private func notificationStatusText(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return String(localized: "push_server_notification_status_undetermined")
        case .denied: return String(localized: "push_server_notification_status_denied_hint")
        case .authorized: return String(localized: "push_server_notification_status_authorized")
        case .provisional: return String(localized: "push_server_notification_status_provisional")
        case .ephemeral: return String(localized: "push_server_notification_status_ephemeral")
        @unknown default: return String(localized: "push_server_notification_status_unknown")
        }
    }
}
