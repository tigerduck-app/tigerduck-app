import Foundation
import SwiftUI
import Testing
@testable import TigerDuck

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

@MainActor
private final class ShownSyncConflicts {
    var conflicts: [AppState.SyncConflictItem] = []
}
