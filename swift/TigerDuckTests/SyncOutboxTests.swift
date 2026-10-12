// `SyncOutbox.drain`: which failures count against an edit, and what happens to a mark the
// server keeps refusing. A dropped mark used to be lost, since the next pull replaced it.
import Foundation
import Testing
@testable import TigerDuck

struct SyncOutboxTests {
    private static func makeOutbox(directory: URL = Self.freshDirectory()) -> SyncOutbox {
        SyncOutbox(directory: directory)
    }

    private static func freshDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncOutboxTests-\(UUID().uuidString)", isDirectory: true)
    }

    private static let mark = SyncOp.assignmentOverride(
        moodleCourseId: 0, moodleAssignmentId: 42, localStatus: "ignored", stamp: Date())

    private static let colour = SyncOp.courseOverride(
        semester: "1151", moodleId: "1151CS1001301", customName: nil, colorHex: "#FF6B6B",
        locale: nil, stamp: Date())

    private static func drain(_ outbox: SyncOutbox, times: Int = 1, failingWith error: Error) async {
        for _ in 0..<times {
            await outbox.drain { _ in throw error }
        }
    }

    @Test("A server error, timeout or rate limit keeps the edit without counting an attempt",
          arguments: [500, 502, 503, 408, 429])
    func serverTroubleKeepsTheEdit(status: Int) async {
        let outbox = Self.makeOutbox()
        await outbox.enqueue(Self.mark)

        await Self.drain(outbox, times: SyncOutbox.maxAttempts + 1,
                         failingWith: PushAPIError.httpStatus(status, body: ""))

        let entries = await outbox.snapshot()
        #expect(entries.count == 1)
        #expect(entries.first?.attempts == 0)
    }

    @Test("A mark the server refuses five times is parked, not dropped")
    func refusedMarkIsParked() async {
        let outbox = Self.makeOutbox()
        await outbox.enqueue(Self.mark)

        await Self.drain(outbox, times: SyncOutbox.maxAttempts,
                         failingWith: PushAPIError.httpStatus(404, body: ""))

        #expect(await outbox.pendingCount() == 0)
        #expect(await outbox.parkedSnapshot().map(\.op.dedupKey) == [Self.mark.dedupKey])
    }

    @Test("A course override the server refuses five times is dropped")
    func refusedCourseOverrideIsDropped() async {
        let outbox = Self.makeOutbox()
        await outbox.enqueue(Self.colour)

        await Self.drain(outbox, times: SyncOutbox.maxAttempts,
                         failingWith: PushAPIError.httpStatus(404, body: ""))

        #expect(await outbox.pendingCount() == 0)
        #expect(await outbox.parkedSnapshot().isEmpty)
    }

    @Test("A requeued mark gets one more try, and leaves the outbox once it lands")
    func requeuedMarkGetsOneTry() async {
        let outbox = Self.makeOutbox()
        await outbox.enqueue(Self.mark)
        await Self.drain(outbox, times: SyncOutbox.maxAttempts,
                         failingWith: PushAPIError.httpStatus(404, body: ""))

        await outbox.requeueParked()
        #expect(await outbox.pendingCount() == 1)
        await Self.drain(outbox, failingWith: PushAPIError.httpStatus(404, body: ""))
        #expect(await outbox.pendingCount() == 0)
        #expect(await outbox.parkedSnapshot().count == 1)

        await outbox.requeueParked()
        await outbox.drain { _ in }
        #expect(await outbox.pendingCount() == 0)
        #expect(await outbox.parkedSnapshot().isEmpty)
    }

    @Test("A new edit of a parked mark replaces it")
    func newEditReplacesTheParkedMark() async {
        let outbox = Self.makeOutbox()
        await outbox.enqueue(Self.mark)
        await Self.drain(outbox, times: SyncOutbox.maxAttempts,
                         failingWith: PushAPIError.httpStatus(404, body: ""))

        await outbox.enqueue(.assignmentOverride(
            moodleCourseId: 0, moodleAssignmentId: 42, localStatus: "none", stamp: Date()))

        #expect(await outbox.parkedSnapshot().isEmpty)
        #expect(await outbox.snapshot().count == 1)
    }

    @Test("Parked marks survive a relaunch and go with a sign-out")
    func parkedMarksPersistUntilCleared() async {
        let directory = Self.freshDirectory()
        let outbox = Self.makeOutbox(directory: directory)
        await outbox.enqueue(Self.mark)
        await Self.drain(outbox, times: SyncOutbox.maxAttempts,
                         failingWith: PushAPIError.httpStatus(404, body: ""))

        let relaunched = Self.makeOutbox(directory: directory)
        #expect(await relaunched.parkedSnapshot().count == 1)

        await relaunched.clearAll()
        #expect(await Self.makeOutbox(directory: directory).parkedSnapshot().isEmpty)
    }
}

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
