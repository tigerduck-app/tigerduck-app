// Bulletin push off with authorization denied: iOS never re-prompts, so `enablePush()`
// does nothing, and the off-state section has to explain the denial and offer Settings.
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
        for status: UNAuthorizationStatus in [.notDetermined, .authorized, .provisional, .ephemeral] {
            #expect(BulletinNotificationSettingsView.requiresSystemSettingsRoute(for: status) == false)
        }
    }
}
