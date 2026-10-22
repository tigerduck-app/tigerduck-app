import Foundation
import Testing
@testable import TigerDuck

struct AppGroupEntitlementTests {
    private static let unentitled = "group.org.ntust.app.TigerDuck.unentitled-probe"

    @Test func unentitledGroupIsReportedUnavailable() {
        #expect(WidgetSnapshotStore.isAppGroupAvailable(Self.unentitled) == false)
        #expect(CourseCardFontScaleStore.isAppGroupAvailable(Self.unentitled) == false)
    }

    @Test func nilSuiteCheckCannotDetectAMissingEntitlement() {
        #expect(UserDefaults(suiteName: Self.unentitled) != nil)
    }

    @Test func injectedSuiteIsNotHeldToTheEntitlementRequirement() {
        let suite = "AppGroupEntitlementTests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let store = CourseCardFontScaleStore(appGroupIdentifier: suite)
        store.write(1.1)
        #expect(abs(store.read() - 1.1) < 1e-9)
    }
}
