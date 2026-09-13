// Pins `PendingReminderPurgeMigration`'s three behaviours against a fake
// `PendingReminderPurgeCenter` — never the real, process-global
// `UNUserNotificationCenter`:
//
//   1. `LA-reminder-*` pending requests are removed.
//   2. Requests under any other prefix are left alone — the fake below
//      always mixes reminder and non-reminder identifiers in the same
//      pending list so this can't pass just because there was nothing
//      else to leave alone.
//   3. A second call, after the flag is set, does nothing — proven by
//      handing the second call a *fresh* `LA-reminder-*` request that
//      would be removed if the guard were not working, then asserting it
//      still survives.
//
// `doneKey` mirrors `PendingReminderPurgeMigration`'s own private
// `UserDefaults.standard` flag literal ("PendingReminderPurgeMigration.v1.done").
// It has to be duplicated here rather than referenced because the
// production constant is intentionally `private` (matching every other
// migration in this folder) — see Services/Migrations/AGENTS.md. Suite is
// `.serialized` and every test resets the key first because the flag lives
// in real, process-wide `UserDefaults.standard`; without both, Swift
// Testing's default parallel execution would let these three tests race on
// the same key.
import Foundation
import Testing
import UserNotifications
@testable import TigerDuck

private let doneKey = "PendingReminderPurgeMigration.v1.done"

@Suite("Pending reminder purge migration", .serialized)
struct PendingReminderPurgeMigrationTests {

    init() {
        UserDefaults.standard.removeObject(forKey: doneKey)
    }

    // MARK: - Fixtures

    private func request(_ id: String) -> UNNotificationRequest {
        UNNotificationRequest(identifier: id, content: UNMutableNotificationContent(), trigger: nil)
    }

    // MARK: - Tests

    @Test("Removes every LA-reminder- pending request")
    func removesLegacyReminderRequests() async {
        let center = FakePurgeCenter(pending: [
            request("LA-reminder-assignment1::hr24"),
            request("LA-reminder-assignment2::hr2"),
        ])

        await PendingReminderPurgeMigration.runIfNeeded(center: center)

        #expect(center.pendingRequests.isEmpty)
        #expect(Set(center.removedIdentifiers) == [
            "LA-reminder-assignment1::hr24",
            "LA-reminder-assignment2::hr2",
        ])
    }

    @Test("Leaves non-reminder requests untouched")
    func leavesOtherPrefixesAlone() async {
        let center = FakePurgeCenter(pending: [
            request("LA-reminder-assignment1::hr24"),
            request("bulletin-push-42"),
            request("custom_push_popup-7"),
        ])

        await PendingReminderPurgeMigration.runIfNeeded(center: center)

        let survivingIds = Set(center.pendingRequests.map(\.identifier))
        #expect(survivingIds == ["bulletin-push-42", "custom_push_popup-7"])
        #expect(center.removedIdentifiers == ["LA-reminder-assignment1::hr24"])
    }

    @Test("Second run after the flag is set does nothing")
    func secondRunIsNoOp() async {
        let firstCenter = FakePurgeCenter(pending: [request("LA-reminder-assignment1::hr24")])
        await PendingReminderPurgeMigration.runIfNeeded(center: firstCenter)
        #expect(firstCenter.pendingRequests.isEmpty)

        // Fresh center with a *new* legacy-prefixed request. If the
        // idempotency flag were not honoured, this run would remove it
        // exactly like the first one did.
        let secondCenter = FakePurgeCenter(pending: [request("LA-reminder-assignment9::hr1")])
        await PendingReminderPurgeMigration.runIfNeeded(center: secondCenter)

        #expect(secondCenter.pendingRequests.map(\.identifier) == ["LA-reminder-assignment9::hr1"])
        #expect(secondCenter.removedIdentifiers.isEmpty)
    }
}

/// Records what the migration asked it to remove; never touches the real
/// notification centre.
///
/// `nonisolated`, matching `SettingsAPIStub`'s rationale in this same test
/// target: Swift Testing invokes `@Test` bodies off the main actor, but
/// this module's default actor isolation is `MainActor`, so a plain class
/// here would be main-actor-isolated and every call from a test body would
/// warn about crossing an actor boundary. Safe without synchronization —
/// each test constructs and uses its own instance sequentially.
private nonisolated final class FakePurgeCenter: PendingReminderPurgeCenter {
    private(set) var pendingRequests: [UNNotificationRequest]
    private(set) var removedIdentifiers: [String] = []

    init(pending: [UNNotificationRequest]) {
        self.pendingRequests = pending
    }

    func pendingNotificationRequests() async -> [UNNotificationRequest] {
        pendingRequests
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedIdentifiers.append(contentsOf: identifiers)
        pendingRequests.removeAll { identifiers.contains($0.identifier) }
    }
}
