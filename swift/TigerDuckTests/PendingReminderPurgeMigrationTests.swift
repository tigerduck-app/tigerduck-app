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

    private func request(_ id: String) -> UNNotificationRequest {
        UNNotificationRequest(identifier: id, content: UNMutableNotificationContent(), trigger: nil)
    }

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

        let secondCenter = FakePurgeCenter(pending: [request("LA-reminder-assignment9::hr1")])
        await PendingReminderPurgeMigration.runIfNeeded(center: secondCenter)

        #expect(secondCenter.pendingRequests.map(\.identifier) == ["LA-reminder-assignment9::hr1"])
        #expect(secondCenter.removedIdentifiers.isEmpty)
    }
}

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
