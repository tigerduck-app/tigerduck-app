import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct UnchangedUploadTests {
    private static func entry(_ courseNo: String, room: String = "TR-313") -> PushAPI.CourseUploadEntry {
        PushAPI.CourseUploadEntry(
            semester: "1151", courseNo: courseNo, courseName: courseNo, courseNameEn: nil,
            moodleId: nil, credits: 3, classroom: room, instructors: [],
            scheduleJson: ["1": ["3", "4"]], classroomMap: nil
        )
    }

    private static func courses(_ entries: PushAPI.CourseUploadEntry..., forceKeys: [String] = [])
        -> PushAPI.CourseUploadRequest {
        PushAPI.CourseUploadRequest(courses: entries, forceKeys: forceKeys)
    }

    private struct Backend {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        var uploadURL: URL { baseURL.appendingPathComponent("sync/courses/upload") }

        func answer(status: Int = 200, times: Int = 1) {
            for _ in 0..<times {
                SettingsAPIStub.enqueue(.init(statusCode: status, body: Data("{}".utf8)), for: uploadURL)
            }
        }

        var uploads: Int { SettingsAPIStub.requests(for: uploadURL).count }

        @MainActor
        func makeCoordinator() -> PushCoordinator {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [SettingsAPIStub.self]
            let client = PushAPIClient(
                baseURLProvider: { [baseURL] in baseURL },
                session: URLSession(configuration: config),
                authHeaderProvider: { "Bearer test" }
            )
            return PushCoordinator(identity: PushIdentity(uuid: "test-device"), apiClient: client)
        }
    }

    @Test("A list the server took goes again only when it changes or six hours pass")
    func cadence() {
        let now = Date()
        #expect(PushCoordinator.uploadIsDue(accepted: nil, fingerprint: 1, now: now))
        #expect(PushCoordinator.uploadIsDue(accepted: (2, now - 60), fingerprint: 1, now: now))
        #expect(!PushCoordinator.uploadIsDue(accepted: (1, now - 60), fingerprint: 1, now: now))
        #expect(PushCoordinator.uploadIsDue(accepted: (1, now - 6 * 3600), fingerprint: 1, now: now))
    }

    @Test("The same courses in another order are the same list; a changed room is not")
    func fingerprintIgnoresOrderOnly() {
        let one = PushCoordinator.fingerprint(of: Self.courses(Self.entry("CS1"), Self.entry("CS2")))
        let reordered = PushCoordinator.fingerprint(of: Self.courses(Self.entry("CS2"), Self.entry("CS1")))
        let moved = PushCoordinator.fingerprint(of: Self.courses(Self.entry("CS1", room: "IB-101"), Self.entry("CS2")))
        #expect(one == reordered)
        #expect(one != moved)
    }

    @Test("An unchanged list is skipped; force keys, a resend, a reset and another term still go")
    func unchangedListIsSkipped() async throws {
        let backend = Backend()
        backend.answer(times: 5)
        let coordinator = backend.makeCoordinator()
        let list = Self.courses(Self.entry("CS1"))

        #expect(try await coordinator.uploadCoursesIfChanged(list, semester: "1151", isCurrent: { true }))
        #expect(try await !coordinator.uploadCoursesIfChanged(list, semester: "1151", isCurrent: { true }))
        #expect(backend.uploads == 1)

        #expect(try await coordinator.uploadCoursesIfChanged(
            Self.courses(Self.entry("CS1"), forceKeys: ["client:1151:CS1"]), semester: "1151", isCurrent: { true }))
        #expect(try await coordinator.uploadCoursesIfChanged(list, semester: "1151", resend: true, isCurrent: { true }))
        coordinator.forgetUploads(semester: "1151")
        #expect(try await coordinator.uploadCoursesIfChanged(list, semester: "1151", isCurrent: { true }))
        #expect(try await coordinator.uploadCoursesIfChanged(list, semester: "1142", isCurrent: { true }))
        #expect(backend.uploads == 5)
    }

    @Test("A list the server refused goes again")
    func refusedListGoesAgain() async throws {
        let backend = Backend()
        backend.answer(status: 503)
        backend.answer()
        let coordinator = backend.makeCoordinator()
        let list = Self.courses(Self.entry("CS1"))

        await #expect(throws: PushAPIError.self) {
            try await coordinator.uploadCoursesIfChanged(list, semester: "1151", isCurrent: { true })
        }
        #expect(try await coordinator.uploadCoursesIfChanged(list, semester: "1151", isCurrent: { true }))
        #expect(backend.uploads == 2)
    }

    @Test("A course list the server refused counts as unsent until a list of that term goes up or a sign-out forgets it")
    func refusedListIsUnsent() async throws {
        let backend = Backend()
        backend.answer(status: 503)
        backend.answer()
        backend.answer(status: 503)
        let coordinator = backend.makeCoordinator()
        let list = Self.courses(Self.entry("CS1"))
        #expect(!coordinator.holdsUnsentCourseUploads)

        await #expect(throws: PushAPIError.self) {
            try await coordinator.uploadCoursesIfChanged(list, semester: "1151", isCurrent: { true })
        }
        #expect(coordinator.holdsUnsentCourseUploads)
        #expect(try await coordinator.uploadCoursesIfChanged(list, semester: "1151", isCurrent: { true }))
        #expect(!coordinator.holdsUnsentCourseUploads)

        await #expect(throws: PushAPIError.self) {
            try await coordinator.uploadCoursesIfChanged(Self.courses(Self.entry("CS2")), semester: "1151", isCurrent: { true })
        }
        coordinator.forgetUploads()
        #expect(!coordinator.holdsUnsentCourseUploads)
    }

    @Test("A refused edit undone before it went again leaves nothing unsent")
    func refusedEditUndoneIsNotUnsent() async throws {
        let backend = Backend()
        backend.answer()
        backend.answer(status: 503)
        let coordinator = backend.makeCoordinator()
        let taken = Self.courses(Self.entry("CS1"))

        #expect(try await coordinator.uploadCoursesIfChanged(taken, semester: "1151", isCurrent: { true }))
        await #expect(throws: PushAPIError.self) {
            try await coordinator.uploadCoursesIfChanged(Self.courses(Self.entry("CS2")), semester: "1151", isCurrent: { true })
        }
        #expect(coordinator.holdsUnsentCourseUploads)
        #expect(try await !coordinator.uploadCoursesIfChanged(taken, semester: "1151", isCurrent: { true }))

        #expect(!coordinator.holdsUnsentCourseUploads)
        #expect(backend.uploads == 2)
    }

    @MainActor
    private final class Account {
        var isSignedIn = true
    }

    @Test("A course upload cancelled, or failing after its account signed out, leaves nothing unsent")
    func cancelledOrSignedOutFailureIsNotUnsent() async {
        let coordinator = Backend().makeCoordinator()
        let key = UploadLedger.courses("1151")
        _ = try? await coordinator.uploadIfChanged(key, fingerprint: 1, always: false, isCurrent: { true }) {
            throw CancellationError()
        }
        _ = try? await coordinator.uploadIfChanged(key, fingerprint: 1, always: false, isCurrent: { true }) {
            throw URLError(.cancelled)
        }
        #expect(!coordinator.holdsUnsentCourseUploads)

        let account = Account()
        _ = try? await coordinator.uploadIfChanged(key, fingerprint: 1, always: false, isCurrent: { account.isSignedIn }) {
            account.isSignedIn = false
            throw URLError(.timedOut)
        }
        #expect(!coordinator.holdsUnsentCourseUploads)

        _ = try? await coordinator.uploadIfChanged(key, fingerprint: 1, always: false, isCurrent: { true }) {
            throw URLError(.timedOut)
        }
        #expect(coordinator.holdsUnsentCourseUploads)
    }

    @Test("A course list out again unchanged, as a resend of what the server took, is not unsent")
    func unchangedResendInFlightIsNotUnsent() async throws {
        let coordinator = Backend().makeCoordinator()
        let sends = Sends()
        let key = UploadLedger.courses("1151")
        #expect(try await coordinator.uploadIfChanged(key, fingerprint: 1, always: false, isCurrent: { true }) {
            await sends.send(1)
        })

        sends.holds = true
        let resend = Task {
            try await coordinator.uploadIfChanged(key, fingerprint: 1, always: true, isCurrent: { true }) {
                await sends.send(1)
            }
        }
        try await waitUntil { sends.isParked }
        #expect(!coordinator.holdsUnsentCourseUploads)
        sends.release()
        #expect(try await resend.value)
    }

    @Test("A course list counts as unsent while it is out, and an assignment list does not")
    func courseListInFlightIsUnsent() async throws {
        let coordinator = Backend().makeCoordinator()
        let sends = Sends()
        sends.holds = true
        let assignments = Task {
            try await coordinator.uploadIfChanged(UploadLedger.assignments, fingerprint: 1, always: false, isCurrent: { true }) {
                await sends.send(1)
            }
        }
        try await waitUntil { sends.isParked }
        #expect(!coordinator.holdsUnsentCourseUploads)
        sends.release()
        _ = try await assignments.value

        sends.holds = true
        let courses = Task {
            try await coordinator.uploadIfChanged(UploadLedger.courses("1151"), fingerprint: 2, always: false, isCurrent: { true }) {
                await sends.send(2)
            }
        }
        try await waitUntil { sends.isParked }
        #expect(coordinator.holdsUnsentCourseUploads)
        sends.release()
        _ = try await courses.value
        #expect(!coordinator.holdsUnsentCourseUploads)
    }

    @Test("An upload in flight across a reset records nothing, so the reset's refetch still goes")
    func uploadAcrossAForgetRecordsNothing() {
        var ledger = UploadLedger()
        let key = UploadLedger.courses("1151")
        let now = Date()

        let started = ledger.generation(of: key)
        ledger.forget(key)
        ledger.record(key, fingerprint: 1, at: now, startedIn: started)
        #expect(ledger.isDue(key, fingerprint: 1, now: now))

        ledger.record(key, fingerprint: 1, at: now, startedIn: ledger.generation(of: key))
        #expect(!ledger.isDue(key, fingerprint: 1, now: now))
    }

    @Test("A reset of one term leaves other lists in flight free to record; a sign-out stops them all")
    func forgetsReachOnlyTheirLists() {
        var ledger = UploadLedger()
        let reset = UploadLedger.courses("1151")
        let other = UploadLedger.courses("1142")
        let now = Date()

        let otherStarted = ledger.generation(of: other)
        let assignmentsStarted = ledger.generation(of: UploadLedger.assignments)
        ledger.forget(reset)
        ledger.record(other, fingerprint: 1, at: now, startedIn: otherStarted)
        ledger.record(UploadLedger.assignments, fingerprint: 2, at: now, startedIn: assignmentsStarted)
        #expect(!ledger.isDue(other, fingerprint: 1, now: now))
        #expect(!ledger.isDue(UploadLedger.assignments, fingerprint: 2, now: now))

        let started = ledger.generation(of: other)
        ledger.forget(nil)
        ledger.record(other, fingerprint: 3, at: now, startedIn: started)
        #expect(ledger.isDue(other, fingerprint: 3, now: now))
    }

    @MainActor
    private final class Sends {
        private(set) var sent: [Int] = []
        var holds = false
        private var parked: CheckedContinuation<Void, Never>?

        func send(_ list: Int) async {
            sent.append(list)
            if holds {
                holds = false
                await withCheckedContinuation { parked = $0 }
            }
        }

        var isParked: Bool { parked != nil }

        func release() {
            parked?.resume()
            parked = nil
        }
    }

    @Test("An edit undone while its upload is out still goes up after it, and both count as unsent until done")
    func undoneEditStillGoes() async throws {
        let coordinator = Backend().makeCoordinator()
        let sends = Sends()
        let key = UploadLedger.courses("1151")
        #expect(try await coordinator.uploadIfChanged(key, fingerprint: 1, always: false, isCurrent: { true }) { await sends.send(1) })

        sends.holds = true
        let edit = Task { try await coordinator.uploadIfChanged(key, fingerprint: 2, always: false, isCurrent: { true }) { await sends.send(2) } }
        try await waitUntil { sends.isParked }
        let undo = Task { try await coordinator.uploadIfChanged(key, fingerprint: 1, always: false, isCurrent: { true }) { await sends.send(1) } }
        for _ in 0..<50 { await Task.yield() }
        #expect(sends.isParked)
        #expect(coordinator.holdsUnsentCourseUploads)
        sends.release()

        #expect(try await edit.value)
        #expect(try await undo.value)
        #expect(sends.sent == [1, 2, 1])
        #expect(!coordinator.holdsUnsentCourseUploads)
    }

    @Test("An upload queued behind another is dropped if its account signs out while it waits")
    func queuedUploadSkipsAfterSignOut() async throws {
        let coordinator = Backend().makeCoordinator()
        let sends = Sends()
        let key = UploadLedger.assignments
        var signedIn = true

        sends.holds = true
        let first = Task {
            try await coordinator.uploadIfChanged(key, fingerprint: 1, always: false, isCurrent: { true }) {
                await sends.send(1)
            }
        }
        try await waitUntil { sends.isParked }
        let queued = Task {
            try await coordinator.uploadIfChanged(key, fingerprint: 2, always: true, isCurrent: { signedIn }) {
                await sends.send(2)
            }
        }
        signedIn = false
        sends.release()

        #expect(try await first.value)
        #expect(try await !queued.value)
        #expect(sends.sent == [1])
    }
}
