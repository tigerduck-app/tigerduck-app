// 同步課程資訊 has one copy, `Defaults[.cloudSyncEnabled]`, and several
// writers: onboarding, the `@Default`-bound switch in TigerSync settings, the
// Mac toggles through `AppState`, and sign-out. `AppState` has to act on every
// change whichever of them made it — Live Activity ending or resuming, the
// push schedule, `CloudSyncCoordinator` following — and has to read the same
// value they wrote. `CloudSyncPreference` is how it does both; `AppState`
// holds one and forwards `cloudSyncEnabled` to it.
//
// This target cannot construct an `AppState`, so these drive the preference
// directly, on a key of their own in a suite of their own: the running app's
// `AppState` observes the real key and would act on anything written to it
// here.
import Defaults
import Foundation
import Observation
import Testing
@testable import TigerDuck

@Suite("Cloud sync preference")
@MainActor
struct CloudSyncPreferenceTests {

    private static func withIsolatedKey(_ body: (Defaults.Key<Bool>) -> Void) {
        let suiteName = "CloudSyncPreferenceTests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        body(Defaults.Key<Bool>("cloudSyncEnabled", default: true, suite: suite))
    }

    /// Set from `withObservationTracking`'s `onChange`, which is `@Sendable`.
    private final class Flag: @unchecked Sendable {
        var raised = false
    }

    @Test("a write that bypasses AppState is seen: the reading follows it and the change is reported")
    func writeThatBypassesAppStateIsSeen() {
        Self.withIsolatedKey { key in
            let preference = CloudSyncPreference(key: key)
            var reported: [Bool] = []
            preference.onChange { reported.append($0) }

            // What onboarding's "Next" and the `@Default`-bound switch in
            // TigerSync settings do: write the preference itself.
            Defaults[key] = false

            #expect(preference.isEnabled == false)
            #expect(reported == [false])
        }
    }

    @Test("sync can be turned back on in the same process after another writer turned it off")
    func turnsBackOnAfterAnotherWriterTurnedItOff() {
        Self.withIsolatedKey { key in
            let preference = CloudSyncPreference(key: key)
            var reported: [Bool] = []
            preference.onChange { reported.append($0) }

            // Sign-out, as it was: `CloudSyncCoordinator` wrote the
            // preference itself, behind AppState's back.
            Defaults[key] = false
            // Then the switch in Settings, without a relaunch.
            preference.isEnabled = true

            #expect(reported == [false, true])
            #expect(Defaults[key] == true)
        }
    }

    @Test("a write that bypasses AppState still tells the screens reading it to refresh")
    func writeThatBypassesAppStateInvalidatesReaders() {
        Self.withIsolatedKey { key in
            let preference = CloudSyncPreference(key: key)
            let invalidated = Flag()
            withObservationTracking {
                _ = preference.isEnabled
            } onChange: {
                invalidated.raised = true
            }

            Defaults[key] = false

            #expect(invalidated.raised)
        }
    }
}
