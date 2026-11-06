import Foundation
import os
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

    @Test("An edit made in a sign-in that has ended is not queued")
    func anEditOfAnEndedSignInIsNotQueued() async {
        let outbox = Self.makeOutbox()
        await outbox.enqueue(Self.mark, for: endedTestSignIn)
        #expect(await outbox.pendingCount() == 0)
    }

    @Test("A drain sends each edit for the sign-in it was made in, and one read from disk for its own")
    func aDrainSendsEachEditForItsOwnSignIn() async {
        let directory = Self.freshDirectory()
        await Self.makeOutbox(directory: directory).enqueue(Self.mark, for: testSignIn)
        let outbox = Self.makeOutbox(directory: directory)
        let made = TestSignIn()
        await outbox.enqueue(Self.colour, for: made.signIn)
        let drained = TestSignIn()
        let sent = OSAllocatedUnfairLock<[SignIn]>(initialState: [])

        await outbox.drain(for: drained.signIn) { _, signIn in sent.withLock { $0.append(signIn) } }

        #expect(sent.withLock { $0 } == [drained.signIn, made.signIn])
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

    @Test("A discard by time drops its scopes' edits made before it, queued, parked or on their way in, and a cutoff past now refuses no later edit")
    func discardByTimeRefusesTheOlderEditsStillToCome() async {
        let outbox = Self.makeOutbox()
        let cutoff = Date()
        let older = cutoff.addingTimeInterval(-60)
        await outbox.enqueue(.courseAdd(semester: "1151", courseNo: "GE1", stamp: older))
        await Self.drain(outbox, times: SyncOutbox.maxAttempts, failingWith: PushAPIError.httpStatus(422, body: ""))
        await outbox.enqueue(.courseAdd(semester: "1151", courseNo: "GE2", stamp: older))
        await outbox.enqueue(.courseAdd(semester: "1151", courseNo: "GE3", stamp: cutoff.addingTimeInterval(60)))
        await outbox.enqueue(Self.mark)

        let dropped = await outbox.discard(
            madeBefore: [.allCourseAdds: cutoff, .courseDelete(key: "1151:PE7"): Date().addingTimeInterval(3600)], notAfter: Date(),
            takenIn: SyncClock.isolated().era
        )
        await outbox.enqueue(.courseAdd(semester: "1151", courseNo: "GE4", stamp: older))
        await outbox.enqueue(.courseAdd(semester: "1151", courseNo: "GE5", stamp: Date()))
        await outbox.enqueue(.courseDelete(semester: "1151", courseNo: "GE6", stamp: older))
        await outbox.enqueue(.courseDelete(semester: "1151", courseNo: "PE7", stamp: Date()))

        #expect(Set(dropped.map(\.dedupKey)) == ["ca|1151|GE1", "ca|1151|GE2"])
        #expect(await outbox.parkedSnapshot().isEmpty)
        #expect(await outbox.snapshot().map(\.op.dedupKey)
            == ["ca|1151|GE3", Self.mark.dedupKey, "ca|1151|GE5", "cd|1151|GE6", "cd|1151|PE7"])
    }

    @Test("A held mark stays queued and untried while the edits behind it go")
    func heldMarkWaitsWhileOthersGo() async {
        let outbox = Self.makeOutbox()
        await outbox.enqueue(Self.mark)
        await outbox.enqueue(Self.colour)
        let sent = Sent()

        await outbox.drain(holding: { op in
            if case .assignmentOverride = op { return true }
            return false
        }) { op in await sent.add(op) }

        #expect(await sent.count == 1)
        #expect(await outbox.snapshot().map(\.op.dedupKey) == [Self.mark.dedupKey])
        #expect(await outbox.snapshot().first?.attempts == 0)
    }

    private actor Sent {
        private(set) var count = 0
        func add(_ op: SyncOp) { count += 1 }
    }

    @Test("Clearing the queue forgets its discard cutoffs, so the next account's edits are not refused by them")
    func clearingForgetsTheCutoffs() async {
        let outbox = Self.makeOutbox()
        let earlier = SyncOp.assignmentOverride(
            moodleCourseId: 0, moodleAssignmentId: 42, localStatus: "ignored", stamp: Date().addingTimeInterval(-60))
        await outbox.discard(madeBefore: [.assignmentMarks: Date()], notAfter: Date(), takenIn: SyncClock.isolated().era)

        await outbox.clearAll()
        await outbox.enqueue(earlier)

        #expect(await outbox.snapshot().map(\.op.dedupKey) == [earlier.dedupKey])
    }

    @Test("A full sync that requeues during the drain parking a mark keeps it parked")
    func requeueDuringTheParkingDrainKeepsTheMark() async {
        let outbox = Self.makeOutbox()
        await outbox.enqueue(Self.mark)
        await Self.drain(outbox, times: SyncOutbox.maxAttempts - 1,
                         failingWith: PushAPIError.httpStatus(404, body: ""))
        await outbox.enqueue(Self.colour)

        await outbox.drain { op in
            if case .assignmentOverride = op { throw PushAPIError.httpStatus(404, body: "") }
            await outbox.requeueParked()
        }

        #expect(await outbox.parkedSnapshot().map(\.op.dedupKey) == [Self.mark.dedupKey])
        #expect(await outbox.snapshot().isEmpty)
    }

    @Test("An ahead refusal from a server the client has left since costs the edit no attempt")
    func aRefusalFromALeftServerCostsNoAttempt() async {
        let outbox = Self.makeOutbox()
        await outbox.enqueue(Self.colour)

        await Self.drain(outbox, times: SyncOutbox.maxAttempts, failingWith: PushAPIError.clockAhead(serverClock: nil))

        #expect(await outbox.snapshot().map(\.attempts) == [0])
    }

    @Test("A pull-back during a drain moves the edits that drain keeps and parks")
    func aPullBackDuringADrainMovesWhatItKeepsAndParks() async {
        let outbox = Self.makeOutbox()
        let ahead = PushAPI.date(ofClock: SyncClockTests.ten + SyncClockTests.year)
        let pullBack = SyncClock.PullBack(ceiling: SyncClockTests.ten, top: SyncClockTests.ten + SyncClockTests.year)
        let kept = SyncOp.assignmentOverride(moodleCourseId: 0, moodleAssignmentId: 42, localStatus: "ignored", stamp: ahead)
        let parked = SyncOp.assignmentOverride(moodleCourseId: 0, moodleAssignmentId: 43, localStatus: "ignored", stamp: ahead)
        await outbox.enqueue(kept)
        await outbox.enqueue(parked)
        for _ in 1..<SyncOutbox.maxAttempts {
            await outbox.drain(holding: { $0.dedupKey == kept.dedupKey }) { _ in throw PushAPIError.httpStatus(422, body: "") }
        }

        await outbox.drain { op in
            if op.dedupKey == parked.dedupKey { await outbox.restamp(after: pullBack) }
            throw PushAPIError.httpStatus(422, body: "")
        }

        let moved = pullBack.restamped(ahead)
        #expect(await outbox.snapshot().map(\.op.stamp) == [moved])
        #expect(await outbox.parkedSnapshot().map(\.op.stamp) == [moved])
    }

    nonisolated private final class ReadGate: @unchecked Sendable {
        private let lock = NSLock()
        private var locked = true
        var isLocked: Bool {
            get { lock.withLock { locked } }
            set { lock.withLock { locked = newValue } }
        }
    }

    /// A launch behind the lock screen cannot read the queue (`completeFileProtectionUnlessOpen`).
    /// An edit made then must not be written over it, and joins it once it can be read.
    @Test func aQueueThatCannotBeReadYetIsKeptAndJoined() async throws {
        let directory = Self.freshDirectory()
        await Self.makeOutbox(directory: directory).enqueue(Self.mark)

        let gate = ReadGate()
        let relaunched = SyncOutbox(directory: directory) { url in
            guard !gate.isLocked else { throw CocoaError(.fileReadNoPermission) }
            return try Data(contentsOf: url)
        }
        await relaunched.enqueue(Self.colour)
        #expect(await Self.makeOutbox(directory: directory).snapshot().map(\.op.dedupKey) == [Self.mark.dedupKey])

        gate.isLocked = false
        #expect(await relaunched.snapshot().map(\.op.dedupKey) == [Self.mark.dedupKey, Self.colour.dedupKey])
        #expect(await Self.makeOutbox(directory: directory).snapshot().count == 2)
    }

    private static func onDisk(_ directory: URL) async -> [String] {
        await makeOutbox(directory: directory).snapshot().map(\.op.dedupKey)
    }

    @Test func aQueueUnreadableWhileUnlockedIsGivenUpOnAndReplaced() async {
        let directory = Self.freshDirectory()
        await Self.makeOutbox(directory: directory).enqueue(Self.mark)
        let relaunched = SyncOutbox(directory: directory) { _ in throw CocoaError(.fileReadNoPermission) }
        await relaunched.enqueue(Self.colour)

        for _ in 0...SyncOutbox.unreadableLoadLimit {
            await relaunched.loadOrGiveUp(protectedDataAvailable: false)
        }
        #expect(await Self.onDisk(directory) == [Self.mark.dedupKey])

        for _ in 1..<SyncOutbox.unreadableLoadLimit {
            await relaunched.loadOrGiveUp(protectedDataAvailable: true)
        }
        #expect(await Self.onDisk(directory) == [Self.mark.dedupKey])

        await relaunched.loadOrGiveUp(protectedDataAvailable: true)
        #expect(await Self.onDisk(directory) == [Self.colour.dedupKey])
        #expect(await relaunched.snapshot().map(\.op.dedupKey) == [Self.colour.dedupKey])
    }

    @Test func givingUpKeepsTheQueueFileThatCanBeRead() async {
        let directory = Self.freshDirectory()
        await Self.makeOutbox(directory: directory).enqueue(Self.mark)
        let relaunched = SyncOutbox(directory: directory) { url in
            guard url.lastPathComponent != "outbox-parked.json" else { throw CocoaError(.fileReadNoPermission) }
            return try Data(contentsOf: url)
        }
        await relaunched.enqueue(Self.colour)

        for _ in 0..<SyncOutbox.unreadableLoadLimit {
            await relaunched.loadOrGiveUp(protectedDataAvailable: true)
        }

        #expect(await Self.onDisk(directory) == [Self.mark.dedupKey, Self.colour.dedupKey])
    }
}
