// `CloudSyncCoordinator` drains the outbox against a stubbed backend (`SettingsAPIStub`): which
// requests a tick sends, and what it leaves queued.
import Foundation
import Testing
import os
@testable import TigerDuck

@MainActor
struct CloudSyncCoordinatorTests {
    private struct Backend {
        let baseURL = SettingsAPIStub.uniqueBaseURL()

        func url(_ path: String) -> URL { baseURL.appendingPathComponent(path) }

        func requests(_ path: String) -> [URLRequest] { SettingsAPIStub.requests(for: url(path)) }

        func answer(_ path: String, status: Int = 200, body: String = "{}") {
            SettingsAPIStub.enqueue(.init(statusCode: status, body: Data(body.utf8)), for: url(path))
        }
    }

    private static func makeCoordinator(
        _ backend: Backend,
        syncsAssignmentMarks: @escaping @Sendable () -> Bool = { true }
    ) -> CloudSyncCoordinator {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        let client = PushAPIClient(
            baseURLProvider: { [baseURL = backend.baseURL] in baseURL },
            session: URLSession(configuration: config)
        )
        let push = PushCoordinator(identity: PushIdentity(uuid: "test-device"), apiClient: client)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudSyncCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        return CloudSyncCoordinator(
            pushCoordinator: push, outbox: SyncOutbox(directory: directory), isEnabled: true,
            syncsAssignmentMarks: syncsAssignmentMarks
        )
    }

    private static let markReply = #"{"id":1,"local_status":"ignored","updated_at":"2026-10-12T00:00:00+00:00"}"#

    @Test("A tick with nothing queued sends no request")
    func emptyTickSendsNothing() async {
        let backend = Backend()
        let coordinator = Self.makeCoordinator(backend)

        await coordinator.syncTick()

        #expect(backend.requests("sync/full").isEmpty)
    }

    @Test("A tick sends the queued mark and never fetches /sync/full")
    func tickSendsOnlyTheQueuedMark() async {
        let backend = Backend()
        backend.answer("sync/assignments/42/override", body: Self.markReply)
        let coordinator = Self.makeCoordinator(backend)
        await coordinator.enqueueAssignmentOverride(moodleCourseId: 0, moodleAssignmentId: 42, localStatus: "ignored")

        await coordinator.syncTick()

        #expect(backend.requests("sync/assignments/42/override").count == 1)
        #expect(backend.requests("sync/full").isEmpty)
        #expect(await coordinator.outbox.pendingCount() == 0)
    }

    @Test("A mark the backend answers 503 stays queued for a later tick")
    func serverErrorKeepsTheMarkQueued() async {
        let backend = Backend()
        for _ in 0...SyncOutbox.maxAttempts {
            backend.answer("sync/assignments/42/override", status: 503)
        }
        let coordinator = Self.makeCoordinator(backend)
        await coordinator.enqueueAssignmentOverride(moodleCourseId: 0, moodleAssignmentId: 42, localStatus: "ignored")

        for _ in 0...SyncOutbox.maxAttempts { await coordinator.syncTick() }

        #expect(await coordinator.outbox.snapshot().map(\.attempts) == [0])
    }

    @Test("A mark the backend keeps refusing still counts as pending, so a pull leaves it alone")
    func refusedMarkStaysPending() async {
        let backend = Backend()
        for _ in 0..<SyncOutbox.maxAttempts {
            backend.answer("sync/assignments/42/override", status: 404)
        }
        let coordinator = Self.makeCoordinator(backend)
        await coordinator.enqueueAssignmentOverride(moodleCourseId: 0, moodleAssignmentId: 42, localStatus: "ignored")

        for _ in 0..<SyncOutbox.maxAttempts { await coordinator.syncTick() }

        #expect(await coordinator.outbox.pendingCount() == 0)
        #expect(await coordinator.pendingAssignmentOverrideIds() == ["42"])
    }

    @Test("Clearing a mark leaves the outbox after one request, though its reply is not the row")
    func clearedMarkIsSentOnce() async {
        let backend = Backend()
        backend.answer("sync/assignments/42/override", body: #"{"deleted": true}"#)
        let coordinator = Self.makeCoordinator(backend)
        await coordinator.enqueueAssignmentOverride(moodleCourseId: 0, moodleAssignmentId: 42, localStatus: "none")

        for _ in 0..<SyncOutbox.maxAttempts { await coordinator.syncTick() }

        #expect(backend.requests("sync/assignments/42/override").count == 1)
        #expect(await coordinator.outbox.pendingCount() == 0)
        #expect(await coordinator.pendingAssignmentOverrideIds().isEmpty)
    }

    @Test("With the Assignments switch off a queued mark waits, and a queued colour still goes")
    func switchOffHoldsQueuedMarks() async {
        let backend = Backend()
        backend.answer("sync/courses/1151CS1001301/override", body: Self.colourReply)
        backend.answer("sync/assignments/42/override", body: Self.markReply)
        let syncsMarks = OSAllocatedUnfairLock(initialState: false)
        let coordinator = Self.makeCoordinator(backend) { syncsMarks.withLock { $0 } }
        await coordinator.enqueueAssignmentOverride(moodleCourseId: 0, moodleAssignmentId: 42, localStatus: "ignored")
        coordinator.enqueueCourseColorOverride(moodleId: "1151CS1001301", semester: "1151", colorHex: "#FF6B6B")
        // The colour is queued from a task of its own.
        for _ in 0..<2000 {
            if await coordinator.outbox.pendingCount() == 2 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }

        await coordinator.syncTick()
        #expect(backend.requests("sync/courses/1151CS1001301/override").count == 1)
        #expect(backend.requests("sync/assignments/42/override").isEmpty)
        #expect(await coordinator.outbox.pendingCount() == 1)

        syncsMarks.withLock { $0 = true }
        await coordinator.syncTick()
        #expect(backend.requests("sync/assignments/42/override").count == 1)
        #expect(await coordinator.outbox.pendingCount() == 0)
    }

    @Test("A mark after the switch went off mid-drain stays queued")
    func switchTurnedOffMidDrainHoldsTheRest() async {
        let backend = Backend()
        backend.answer("sync/assignments/42/override", body: Self.markReply)
        backend.answer("sync/assignments/43/override", body: Self.markReply)
        // On for the first mark and off from the second, as if turned off while the first went.
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let coordinator = Self.makeCoordinator(backend) {
            reads.withLock { count in
                count += 1
                return count == 1
            }
        }
        await coordinator.enqueueAssignmentOverride(moodleCourseId: 0, moodleAssignmentId: 42, localStatus: "ignored")
        await coordinator.enqueueAssignmentOverride(moodleCourseId: 0, moodleAssignmentId: 43, localStatus: "ignored")

        await coordinator.syncTick()

        #expect(backend.requests("sync/assignments/42/override").count == 1)
        #expect(backend.requests("sync/assignments/43/override").isEmpty)
        #expect(await coordinator.outbox.pendingCount() == 1)
    }

    private static let colourReply =
        ##"{"id":1,"color_hex":"#FF6B6B","custom_names":{},"updated_at":"2026-10-12T00:00:00+00:00"}"##
}
