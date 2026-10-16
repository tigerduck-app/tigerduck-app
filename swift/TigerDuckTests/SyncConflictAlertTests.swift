import Foundation
import SwiftUI
import Testing
@testable import TigerDuck

/// `AppState.syncConflictAlertIsPresented`, the binding of the alert for assignments marked
/// differently here and on the server. Closed without a button, it answered Use Local, which sends
/// this device's marks over the server's (https://github.com/tigerduck-app/tigerduck-app/issues/403).
@MainActor
struct SyncConflictAlertTests {
    @Test("Closing the assignment conflict alert without a button hides it and answers nothing")
    func closingTheAlertUnansweredHidesIt() {
        let shown = ShownSyncConflicts()
        shown.conflicts = [AppState.SyncConflictItem(
            id: "42", kind: "Assignment", label: "Lab 1", localStatus: "ignored", serverStatus: "locally_completed"
        )]
        let isPresented = AppState.syncConflictAlertIsPresented(
            Binding(get: { shown.conflicts }, set: { shown.conflicts = $0 })
        )
        #expect(isPresented.wrappedValue)

        isPresented.wrappedValue = false

        #expect(!isPresented.wrappedValue)
        #expect(shown.conflicts.isEmpty)
    }
}

/// The test host builds no `AppState`, so this holds the conflicts the alert's binding shows.
@MainActor
private final class ShownSyncConflicts {
    var conflicts: [AppState.SyncConflictItem] = []
}
