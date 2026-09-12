import ActivityKit
import SwiftUI
import UserNotifications

/// 通知權限設定 (spec §6, owner's ruling 2026-09-12, item 4): the system-level
/// authorization for Notifications and for Live Activities, each row
/// tappable to jump into system Settings so the user can flip it there.
/// iPhone/iPad only — reached from a NavigationLink in SettingsView that
/// macOS's settings scene has no equivalent of. Excluded from the macOS
/// build via `tools/macos-excluded-sources.txt` rather than an
/// `#if os(macOS)` guard in here, matching `BulletinNotificationSettingsView`.
///
/// Reads the same two authorization sources `LiveActivityCoordinator` and
/// `PushCoordinator` already read elsewhere
/// (`UNUserNotificationCenter.current().notificationSettings()` and
/// `ActivityAuthorizationInfo().areActivitiesEnabled`) rather than a second
/// way of asking.
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
        case notApplicable

        var text: String {
            switch self {
            case .granted: return String(localized: "permission_granted")
            case .notGranted: return String(localized: "permission_not_granted_tap_settings")
            case .notApplicable: return String(localized: "permission_not_applicable")
            }
        }

        var color: Color {
            switch self {
            case .granted: return .green
            case .notGranted: return .orange
            case .notApplicable: return .secondary
            }
        }

        var systemImage: String {
            switch self {
            case .granted: return "checkmark.circle.fill"
            case .notGranted: return "exclamationmark.triangle.fill"
            case .notApplicable: return "minus.circle.fill"
            }
        }
    }

    /// Same authorized/not split as `SettingsView.refreshNotificationsAuthorization()`:
    /// `.authorized`, `.provisional`, and `.ephemeral` all count as granted.
    /// Never `.notApplicable` — every iPhone/iPad in this app's deployment
    /// target has a real notification-authorization concept.
    static func notificationPermissionStatus(for status: UNAuthorizationStatus) -> RowStatus {
        switch status {
        case .authorized, .provisional, .ephemeral: return .granted
        case .denied, .notDetermined: return .notGranted
        @unknown default: return .notGranted
        }
    }

    /// `ActivityAuthorizationInfo().areActivitiesEnabled` is a plain Bool on
    /// this app's deployment target — never `.notApplicable` for the same
    /// reason as the notification row above.
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
