import Foundation
import Testing
@testable import TigerDuck

/// The three App-Group-backed stores (`WidgetSnapshotStore`, `SharedSnapshotStore`,
/// `CourseCardFontScaleStore`) promise in their doc comments to crash in DEBUG
/// rather than let a missing `com.apple.security.application-groups` entry ship.
///
/// A `UserDefaults(suiteName:) != nil` gate cannot keep that promise: the initializer
/// returns nil only for reserved names (this process's bundle identifier, `NSGlobalDomain`).
/// An unentitled group gets a valid but process-local store, so the extension never
/// sees the app's writes and neither the assertion nor `logger.error` fires.
struct AppGroupEntitlementTests {
    /// Shaped like a real App Group so nothing can pass this by sniffing the
    /// identifier, but no target in this project is entitled to it.
    private static let unentitled = "group.org.ntust.app.TigerDuck.unentitled-probe"

    @Test func unentitledGroupIsReportedUnavailable() {
        #expect(WidgetSnapshotStore.isAppGroupAvailable(Self.unentitled) == false)
        #expect(SharedSnapshotStore.isAppGroupAvailable(Self.unentitled) == false)
        #expect(CourseCardFontScaleStore.isAppGroupAvailable(Self.unentitled) == false)
    }

    /// Pins the platform behaviour that made the old check useless. If this
    /// ever starts failing, `UserDefaults(suiteName:)` became a real
    /// availability test and the container-URL check could be revisited —
    /// until then, deleting it silently reopens the bug.
    @Test func nilSuiteCheckCannotDetectAMissingEntitlement() {
        #expect(UserDefaults(suiteName: Self.unentitled) != nil)
    }

    /// The stores only demand a reachable container for the App Group they
    /// actually ship with; an injected identifier stays a plain suite so
    /// tests (e.g. `CourseCardFontScaleTests`) can still inject one without
    /// tripping the DEBUG assertion.
    @Test func injectedSuiteIsNotHeldToTheEntitlementRequirement() {
        let suite = "AppGroupEntitlementTests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let store = CourseCardFontScaleStore(appGroupIdentifier: suite)
        store.write(1.1)
        #expect(abs(store.read() - 1.1) < 1e-9)
    }
}
