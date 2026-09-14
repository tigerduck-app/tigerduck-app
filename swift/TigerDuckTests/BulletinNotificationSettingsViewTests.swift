// 公告推播 off, OS authorization denied: `enablePush()` cannot move that
// state at all — iOS never re-prompts after a refusal, so
// `requestAuthorization` returns `false` without showing the user
// anything and the method returns at its guard. The on-state branch's
// permission row and its 在系統設定中重新開啟 button are unreachable while
// the flag is off, so the off-state branch has to carry both, or the tap
// is a dead end. `BulletinPushOptOutMigration` puts every 2.0.x user who
// turned push off into exactly that state on their first 2.1.0 launch.
//
// `requiresSystemSettingsRoute(for:)` is that decision, and the only
// piece of this screen's own logic a unit test can reach: the rest is a
// SwiftUI `List`, a `BulletinSubscriptionsStore` network round trip, and
// direct reads of `UNUserNotificationCenter`, none of which this target
// constructs. Lifted to a `static` function of a plain value for the same
// reason `NotificationPermissionSettingsView`'s two mappings were.
import Testing
import UserNotifications
@testable import TigerDuck

@Suite("Bulletin push permission routing")
struct BulletinNotificationSettingsViewTests {
    @Test("a denied authorization gets the explanation and the way out")
    func deniedStatusOffersSystemSettings() {
        #expect(BulletinNotificationSettingsView.requiresSystemSettingsRoute(for: .denied))
    }

    @Test("a status the enable button can still move is left to the enable button")
    func actionableStatusesSkipTheDetour() {
        // `.notDetermined` still prompts; the three granted-ish statuses
        // let `enablePush()` through its guard. Offering Settings in any
        // of them would send the user out of the app for nothing.
        for status: UNAuthorizationStatus in [.notDetermined, .authorized, .provisional, .ephemeral] {
            #expect(BulletinNotificationSettingsView.requiresSystemSettingsRoute(for: status) == false)
        }
    }
}
