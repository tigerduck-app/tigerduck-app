import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct RefreshOrderTests {
    @MainActor
    private final class Log {
        var events: [String] = []
    }

    @MainActor
    private final class Backend: SchoolDataBackend {
        let log: Log

        init(log: Log) {
            self.log = log
        }

        func uploadCoursesIfChanged(
            _ request: PushAPI.CourseUploadRequest, semester: String, resend: Bool, addedAt stamp: Date?,
            isCurrent: @escaping @MainActor () -> Bool
        ) async throws -> Bool {
            log.events.append("upload")
            return true
        }

        func uploadAssignmentsIfChanged(
            _ request: PushAPI.AssignmentUploadRequest, isCurrent: @escaping @MainActor () -> Bool
        ) async throws -> Bool {
            log.events.append("upload")
            return true
        }
    }

    @MainActor
    private final class Gate {
        private var opened = false
        private var waiting: CheckedContinuation<Void, Never>?

        func wait() async {
            guard !opened else { return }
            await withCheckedContinuation { waiting = $0 }
        }

        func open() {
            opened = true
            waiting?.resume()
            waiting = nil
        }
    }

    private static func uploader(_ account: AccountSession, _ target: SyncTarget, _ log: Log) -> SchoolDataUploader {
        SchoolDataUploader(
            account: account, target: target, backend: Backend(log: log),
            policy: { SyncPolicy(cloudSyncEnabled: true, switchedOn: ["courses"], pendingChecks: []) }
        )
    }

    private static var course: SDCourse { SDCourse(courseNo: "CS1001301", courseName: "Algorithms") }

    @Test("A school fetch that finishes before the pull applies and uploads only after the pull and the outbox")
    func aSchoolFetchFinishingFirstUploadsAfterThePull() async throws {
        let account = AccountSession()
        let target = SyncTarget(account: account)
        let log = Log()
        let uploader = Self.uploader(account, target, log)
        let pull = Gate()
        let ticket = account.ticket

        let refresh = Task {
            await RefreshOrder.run(
                pull: {
                    await pull.wait()
                    target.notePull(ticket)
                    log.events.append("pulled")
                },
                pushOutbox: { log.events.append("outbox") },
                fetchSchool: { applyAfter in
                    log.events.append("fetched")
                    #expect(await applyAfter())
                    log.events.append("applied")
                    uploader.uploadCourses([Self.course], semester: "1151")
                }
            )
        }
        try await waitUntil { log.events == ["fetched"] }
        for _ in 0..<50 { await Task.yield() }
        #expect(log.events == ["fetched"])

        pull.open()
        await refresh.value
        try await waitUntil { log.events.count == 5 }
        #expect(log.events == ["fetched", "pulled", "outbox", "applied", "upload"])
    }

    @Test("A failed pull lets school data apply but holds its uploads until a later pull")
    func aFailedPullHoldsTheSchoolUploads() async throws {
        let account = AccountSession()
        let target = SyncTarget(account: account)
        let log = Log()
        let uploader = Self.uploader(account, target, log)

        await RefreshOrder.run(
            pull: { log.events.append("pull failed") },
            pushOutbox: { log.events.append("outbox") },
            fetchSchool: { applyAfter in
                #expect(await applyAfter())
                log.events.append("applied")
                uploader.uploadCourses([Self.course], semester: "1151")
            }
        )
        for _ in 0..<50 { await Task.yield() }
        #expect(log.events == ["pull failed", "outbox", "applied"])

        target.notePull(account.ticket)
        try await waitUntil { log.events.last == "upload" }
        #expect(log.events == ["pull failed", "outbox", "applied", "upload"])
    }

    @Test("A refresh cancelled before its pull ends tells its school fetch to apply nothing")
    func aCancelledRefreshAppliesNothing() async throws {
        let log = Log()
        let pull = Gate()
        var applies: Bool?

        let refresh = Task {
            await RefreshOrder.run(
                pull: {
                    await pull.wait()
                    log.events.append("pulled")
                },
                pushOutbox: { log.events.append("outbox") },
                fetchSchool: { applyAfter in
                    log.events.append("fetched")
                    applies = await applyAfter()
                }
            )
        }
        try await waitUntil { log.events == ["fetched"] }
        refresh.cancel()
        pull.open()
        await refresh.value

        #expect(applies == false)
        #expect(log.events == ["fetched", "pulled", "outbox"])
    }

    @Test("A colour edited here and not yet sent survives a pull of an older one, and the push after the pull sends it")
    func anUnsentEditSurvivesAnOlderPull() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let overrideURL = baseURL.appendingPathComponent("sync/courses/client:1151:CS1/override")
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data(Self.colourReply.utf8)), for: overrideURL)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        let client = PushAPIClient(
            baseURLProvider: { baseURL }, session: URLSession(configuration: config),
            authHeaderProvider: { "Bearer test" }
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RefreshOrderTests-\(UUID().uuidString)", isDirectory: true)
        let coordinator = CloudSyncCoordinator(
            pushCoordinator: PushCoordinator(identity: PushIdentity(uuid: "test-device"), apiClient: client),
            outbox: SyncOutbox(directory: directory), isEnabled: true,
            syncsAssignmentMarks: { true }, syncsCourseOverrides: { _ in true }
        )
        let sample = await coordinator.pendingCourseOverrides()
        await coordinator.enqueueCourseColorOverride(moodleId: "1151CS1", semester: "1151", colorHex: "#FF6B6B")?.value
        let olderRows: [[String: Any]] = [
            ["moodle_id": "1151CS1", "color_hex": "#4ECDC4"],
            ["moodle_id": "1151CS2", "color_hex": "#4A90E2"],
        ]
        var taken: [String] = []
        var sentBeforePull = -1

        await RefreshOrder.run(
            pull: {
                sentBeforePull = SettingsAPIStub.requests(for: overrideURL).count
                let held = coordinator.courseOverridesToHold(since: sample).colors
                taken = CourseOverridesReconciler.serverCourseColors(
                    olderRows, courseNos: ["1151CS1": "CS1", "1151CS2": "CS2"], holding: held
                ).map(\.courseNo)
            },
            pushOutbox: { await coordinator.syncTick() },
            fetchSchool: { _ = await $0() }
        )

        #expect(sentBeforePull == 0)
        #expect(taken == ["CS2"])
        let sent = SettingsAPIStub.requests(for: overrideURL)
        #expect(sent.count == 1)
        let body = try #require(sent.first.flatMap(SettingsAPIStub.bodyData(from:)))
        #expect(String(decoding: body, as: UTF8.self).contains("#FF6B6B"))
    }

    private static let colourReply =
        ##"{"id":1,"color_hex":"#FF6B6B","custom_names":{},"updated_at":"2026-10-12T00:00:00+00:00","applied":["color_hex","custom_name","ignore_assignments"]}"##
}
