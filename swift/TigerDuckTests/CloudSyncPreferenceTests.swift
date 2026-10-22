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

    private final class Flag: @unchecked Sendable {
        var raised = false
    }

    @Test("a write that bypasses AppState is seen: the reading follows it and the change is reported")
    func writeThatBypassesAppStateIsSeen() {
        Self.withIsolatedKey { key in
            let preference = CloudSyncPreference(key: key)
            var reported: [Bool] = []
            preference.onChange { reported.append($0) }

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

            Defaults[key] = false
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
