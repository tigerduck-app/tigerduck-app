// `NotificationPermissionSettingsView`'s two rows each collapse a system
// authorization value down to one of three statuses (spec §6, owner's
// ruling 2026-09-12, item 4). That collapse is the one piece of this
// screen's own logic — everything else is either a SwiftUI Form or a
// direct read of `UNUserNotificationCenter`/`ActivityAuthorizationInfo`,
// neither of which this test target can construct or drive.
//
// `notificationPermissionStatus(for:)` and `liveActivityPermissionStatus(enabled:)`
// were lifted from `private` computed properties to `static` functions
// taking plain values, the same move `LiveActivitySettingsViewTests`
// documents for `formatHoursAndMinutes` — no view, store, or environment
// construction involved.
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

    @Test("denied and not-determined notification statuses read as not granted, not as not-applicable")
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
