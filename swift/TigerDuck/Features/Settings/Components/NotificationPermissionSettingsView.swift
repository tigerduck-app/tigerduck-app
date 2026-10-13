import ActivityKit
import SwiftUI
import UserNotifications

/// Notification permission settings: the system authorization for
/// Notifications and for Live Activities, each row opening system Settings to
/// change it. iPhone and iPad only: the SettingsView link that reaches it has
/// no macOS equivalent, so `tools/macos-excluded-sources.txt` drops it from
/// that build instead of an `#if`, like `BulletinNotificationSettingsView`.
/// Reads the same sources as `LiveActivityCoordinator` and `PushCoordinator`:
/// `UNUserNotificationCenter.current().notificationSettings()` and
/// `ActivityAuthorizationInfo().areActivitiesEnabled`.
struct NotificationPermissionSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var liveActivitiesEnabled = false

    var body: some View {
        Form {
            Section {
                permissionRow(
                    label: String(localized: "permission_notifications_name"),
                    status: Self.notificationPermissionStatus(for: notificationStatus)
                )
                permissionRow(
                    label: String(localized: "live_activity_settings_nav_title"),
                    status: Self.liveActivityPermissionStatus(enabled: liveActivitiesEnabled)
                )
            }
        }
        .navigationTitle(String(localized: "notification_permission_settings_nav_title"))
        .task { await refreshStatuses() }
        .onChange(of: scenePhase) { _, newPhase in
            // Same round-trip-from-Settings refresh SettingsView's own
            // notification row uses: these two rows are stale the moment
            // the user backgrounds this app to flip either switch.
            if newPhase == .active {
                Task { await refreshStatuses() }
            }
        }
    }

    /// Internal rather than `private`, and the two mappings below are
    /// `static` functions of plain values rather than instance-computed
    /// properties, so `NotificationPermissionSettingsViewTests` can pin the
    /// decision without constructing a view, environment, or `AppState` —
    /// the same move `LiveActivitySettingsView.formatHoursAndMinutes` made.
    enum RowStatus {
        case granted
        case notGranted

        var text: String {
            switch self {
            case .granted: return String(localized: "permission_granted")
            case .notGranted: return String(localized: "permission_not_granted_tap_settings")
            }
        }

        var color: Color {
            switch self {
            case .granted: return .green
            case .notGranted: return .orange
            }
        }

        var systemImage: String {
            switch self {
            case .granted: return "checkmark.circle.fill"
            case .notGranted: return "exclamationmark.triangle.fill"
            }
        }
    }

    /// Same authorized/not split as `SettingsView.refreshNotificationsAuthorization()`:
    /// `.authorized`, `.provisional`, and `.ephemeral` all count as granted.
    /// Granted or not is the whole answer: every iPhone and iPad this app
    /// deploys to has a real notification-authorization concept.
    static func notificationPermissionStatus(for status: UNAuthorizationStatus) -> RowStatus {
        switch status {
        case .authorized, .provisional, .ephemeral: return .granted
        case .denied, .notDetermined: return .notGranted
        @unknown default: return .notGranted
        }
    }

    /// `ActivityAuthorizationInfo().areActivitiesEnabled` is a plain Bool on
    /// this app's deployment target, so this row is granted or not, the same
    /// as the notification row above.
    static func liveActivityPermissionStatus(enabled: Bool) -> RowStatus {
        enabled ? .granted : .notGranted
    }

    @ViewBuilder
    private func permissionRow(label: String, status: RowStatus) -> some View {
        Button {
            openSystemSettings()
        } label: {
            HStack(spacing: 6) {
                Text(label)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: status.systemImage)
                    .foregroundStyle(status.color)
                Text(status.text)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func refreshStatuses() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let status = settings.authorizationStatus
        let liveActivities = ActivityAuthorizationInfo().areActivitiesEnabled
        await MainActor.run {
            notificationStatus = status
            liveActivitiesEnabled = liveActivities
        }
    }
}
