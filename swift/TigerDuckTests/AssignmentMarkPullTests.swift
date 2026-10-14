// What a full sync and Keep Local do with the done and ignored marks (`AppState+BackendSync.swift`).
import Testing
@testable import TigerDuck

/// `AppState.mergedMarks`: what a pull leaves of one status's marks.
struct MergedMarksTests {
    @Test("Marks follow the server unless an edit of them has not reached it")
    func unprotectedMarksFollowTheServer() {
        let merged = AppState.mergedMarks(server: ["1", "2"], local: ["2", "3"], protected: [])
        #expect(merged == ["1", "2"])
    }

    @Test("An edit not on the server yet keeps the local status, set or cleared")
    func protectedMarksKeepTheLocalStatus() {
        let merged = AppState.mergedMarks(server: ["1", "2"], local: ["3"], protected: ["2", "3"])
        #expect(merged == ["1", "3"])
    }
}

/// `AppState.assignmentMarksToClear`: what Keep Local clears on the server when the re-enabled
/// Assignments switch's check found the marks differ, so that the next full sync keeps them off.
struct KeepLocalMarkTests {
    @Test("Keep Local clears the marks only the server has and leaves this device's")
    func keepLocalClearsServerOnlyMarks() {
        let cleared = AppState.assignmentMarksToClear(server: ["1", "2", "3"], local: ["2", "4"])

        #expect(cleared == ["1", "3"])
    }
}

/// `AppState.uploadsLocalMarksAsFirstSync`. Every sync used to upload a device's marks whenever
/// the server had none, so a stale device brought back marks cleared on another.
struct FirstSyncMarkUploadTests {
    @Test("The account's first sync uploads local marks the server lacks")
    func firstSyncUploadsLocalMarks() {
        #expect(AppState.uploadsLocalMarksAsFirstSync(syncedBefore: false, serverHasMarks: false, localHasMarks: true))
    }

    @Test("After the first sync an empty server is the truth")
    func laterSyncsTakeTheEmptyServer() {
        #expect(!AppState.uploadsLocalMarksAsFirstSync(syncedBefore: true, serverHasMarks: false, localHasMarks: true))
    }

    @Test("Marks on the server are applied, never overwritten by a first sync")
    func serverMarksAreApplied() {
        #expect(!AppState.uploadsLocalMarksAsFirstSync(syncedBefore: false, serverHasMarks: true, localHasMarks: true))
    }
}

/// `AppState.reasonToLeaveMarks`. The Assignments sync switch used to change nothing on the
/// device: marks were still pulled and pushed.
struct MarkPullGateTests {
    @Test("With the Assignments switch off, the server's marks are never applied",
          arguments: [false, true], [false, true])
    func switchOffLeavesMarks(conflictCheckPending: Bool, editedDuringFetch: Bool) {
        let reason = AppState.reasonToLeaveMarks(
            syncsMarks: false, conflictCheckPending: conflictCheckPending,
            uploadedLocalMarks: false, editedDuringFetch: editedDuringFetch
        )
        #expect(reason == .switchedOff)
    }

    @Test("With the switch on and nothing in the way, the server's marks are applied")
    func switchOnAppliesMarks() {
        #expect(AppState.reasonToLeaveMarks(
            syncsMarks: true, conflictCheckPending: false, uploadedLocalMarks: false, editedDuringFetch: false
        ) == nil)
    }
}
