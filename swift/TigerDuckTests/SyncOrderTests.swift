import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct SyncOrderTests {
    @MainActor
    private final class Released {
        var value: FirstPullGate.Release?
        var entered = 0
        var order: [Int] = []
        var pendingChecks: Set<String> = []
    }

    @Test("What this device derives from school data waits for the sign-in's first pull, and goes once it is applied")
    func schoolUploadsWaitForTheFirstPull() async throws {
        let account = AccountSession()
        let target = FirstPullGate()
        let ticket = account.signIns.currentSignIn
        let released = Released()

        let upload = Task { released.value = await target.waitForPull(ticket) }
        for _ in 0..<50 { await Task.yield() }
        #expect(released.value == nil)
        #expect(!target.hasPulled(ticket))

        target.notePull(ticket)
        await upload.value
        #expect(released.value == .pulled)
        #expect(await target.waitForPull(ticket) == .pulled)
    }

    @Test("A sign-out drops the uploads still waiting, and the next sign-in waits for its own pull")
    func aSignOutDropsTheWaitingUploads() async throws {
        let account = AccountSession()
        let target = FirstPullGate()
        let before = account.signIns.currentSignIn
        target.notePull(before)
        let released = Released()

        account.endSignIn()
        let after = account.signIns.currentSignIn
        let upload = Task { released.value = await target.waitForPull(after) }
        for _ in 0..<50 { await Task.yield() }
        #expect(released.value == nil)

        target.signedOut()
        await upload.value
        #expect(released.value == .dropped)
        #expect(!target.hasPulled(before))
        #expect(!target.hasPulled(after))
        target.notePull(before)
        #expect(!target.hasPulled(after))
    }

    @Test("Uploads held for the first pull go out in the order they came, and one that comes as they go follows them")
    func heldUploadsGoInTheirOrder() async throws {
        let account = AccountSession()
        let target = FirstPullGate()
        let ticket = account.signIns.currentSignIn
        let released = Released()
        func held(_ index: Int) -> Task<Void, Never> {
            Task {
                released.entered += 1
                _ = await target.waitForPull(ticket)
                released.order.append(index)
            }
        }

        var uploads: [Task<Void, Never>] = []
        for index in 0..<20 {
            uploads.append(held(index))
            try await waitUntil { released.entered == index + 1 }
        }
        target.notePull(ticket)
        uploads.append(held(20))
        for upload in uploads { await upload.value }

        #expect(released.order == Array(0...20))
    }

    @Test("A full sync reads the switches and the pending checks after settling its course edits")
    func passReadsThePolicyAfterSettling() async throws {
        let state = Released()

        let settled = try await FullSyncRunner.settleCourseEditsThenReadPolicy(
            ["1151|CS1"], takingCourses: true,
            settle: { deletes in
                state.pendingChecks.insert("assignments")
                return deletes
            },
            adds: {
                state.pendingChecks.insert("courses")
                return ["1151|CS2"]
            },
            mayWrite: { true },
            policy: { SyncPolicy(cloudSyncEnabled: true, switchedOn: ["assignments"], pendingChecks: state.pendingChecks) }
        )

        #expect(settled.policy.pendingChecks == ["assignments", "courses"])
        #expect(settled.deletes == ["1151|CS1"])
        #expect(settled.adds == ["1151|CS2"])
    }

    @Test("A full sync that may no longer write once its course edits settle is abandoned")
    func passIsAbandonedWhenItMayNoLongerWrite() async {
        await #expect(throws: FullSyncAbandoned.self) {
            try await FullSyncRunner.settleCourseEditsThenReadPolicy(
                [], takingCourses: true, settle: { $0 }, adds: { [] }, mayWrite: { false },
                policy: { SyncPolicy(cloudSyncEnabled: true, switchedOn: [], pendingChecks: []) }
            )
        }
    }

    @Test("A full sync applies marks, course ignores, colours and names, holidays and then the roster")
    func categoryOrder() {
        #expect(FullSyncRunner.reconcilers.map { $0.category } == [
            "assignments", "course_ignores", "course_overrides", "holidays", "courses",
        ])
    }

    private static let queuedFileFrom3x = #"""
    [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","attempts":2,"op":{"courseOverride":{"semester":"1151","moodleId":"1151CS1001301","colorHex":"#FF6B6B","stamp":815000000.5}}},
     {"id":"6F9619FF-8B86-D011-B42D-00C04FC964F1","attempts":0,"op":{"courseOverride":{"semester":"1151","moodleId":"1151CS1001301","customName":"Algorithms","locale":"zh","stamp":815000001}}},
     {"id":"6F9619FF-8B86-D011-B42D-00C04FC964F2","attempts":0,"op":{"courseIgnore":{"semester":"1151","courseNo":"CS1001301","moodleId":"1151CS1001301","moodleCourseId":4242,"ignore":true,"stamp":815000002}}},
     {"id":"6F9619FF-8B86-D011-B42D-00C04FC964F3","attempts":1,"op":{"courseDelete":{"semester":"1151","courseNo":"EE2005301","stamp":815000003}}},
     {"id":"6F9619FF-8B86-D011-B42D-00C04FC964F4","attempts":0,"op":{"courseAdd":{"semester":"1151","courseNo":"GE1010001","stamp":815000004}}}]
    """#
    private static let parkedFile = #"""
    [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964F5","attempts":5,"op":{"assignmentOverride":{"moodleCourseId":4242,"moodleAssignmentId":42,"localStatus":"ignored","stamp":815000005}}}]
    """#

    @Test("The outbox reads back the files the 3.x app wrote")
    func outboxReadsTheEarlierFiles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncOrderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(Self.queuedFileFrom3x.utf8).write(to: directory.appendingPathComponent("outbox.json"))
        try Data(Self.parkedFile.utf8).write(to: directory.appendingPathComponent("outbox-parked.json"))
        let outbox = SyncOutbox(directory: directory)

        let queued = await outbox.snapshot()
        let parked = await outbox.parkedSnapshot()

        #expect(queued.map(\.op.dedupKey) == [
            "co|1151|1151CS1001301|c|", "co|1151|1151CS1001301|n|zh", "ci|1151|1151CS1001301",
            "cd|1151|EE2005301", "ca|1151|GE1010001",
        ])
        #expect(queued.map(\.attempts) == [2, 0, 0, 1, 0])
        #expect(queued.first?.op.stamp == Date(timeIntervalSinceReferenceDate: 815_000_000.5))
        #expect(parked.map(\.op.dedupKey) == ["ao|4242|42"])
        guard case .courseIgnore(_, _, _, 4242, true, _)? = queued.dropFirst(2).first?.op else {
            Issue.record("expected the ignore setting with its Moodle course id")
            return
        }
    }
}
