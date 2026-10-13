// Each row of `NotificationPermissionSettingsView` collapses a system authorization to
// granted or not granted, the one piece of the screen's own logic. Both mappings are
// static functions of plain values, so no view, store or environment is built.
import Testing
import UserNotifications
@testable import TigerDuck

struct NotificationPermissionSettingsViewTests {
    @Test("authorized, provisional, and ephemeral notification statuses all read as granted")
    func grantedNotificationStatuses() {
        for status: UNAuthorizationStatus in [.authorized, .provisional, .ephemeral] {
            #expect(
                NotificationPermissionSettingsView.notificationPermissionStatus(for: status).text
                    == String(localized: "permission_granted")
            )
        }
    }

    @Test("denied and not-determined notification statuses read as not granted")
    func notGrantedNotificationStatuses() {
        for status: UNAuthorizationStatus in [.denied, .notDetermined] {
            #expect(
                NotificationPermissionSettingsView.notificationPermissionStatus(for: status).text
                    == String(localized: "permission_not_granted_tap_settings")
            )
        }
    }

    @Test("Live Activities enabled reads as granted")
    func liveActivityGranted() {
        #expect(
            NotificationPermissionSettingsView.liveActivityPermissionStatus(enabled: true).text
                == String(localized: "permission_granted")
        )
    }

    @Test("Live Activities disabled reads as not granted")
    func liveActivityNotGranted() {
        #expect(
            NotificationPermissionSettingsView.liveActivityPermissionStatus(enabled: false).text
                == String(localized: "permission_not_granted_tap_settings")
        )
    }
}
