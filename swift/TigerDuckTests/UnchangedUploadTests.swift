// `PushCoordinator.uploadCoursesIfChanged` and `uploadAssignmentsIfChanged`: every course fetch
// and every assignment round used to upload its whole list, unchanged or not.
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
            let client = PushAPIClient(baseURLProvider: { [baseURL] in baseURL }, session: URLSession(configuration: config))
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

        #expect(try await coordinator.uploadCoursesIfChanged(list, semester: "1151"))
        #expect(try await !coordinator.uploadCoursesIfChanged(list, semester: "1151"))
        #expect(backend.uploads == 1)

        #expect(try await coordinator.uploadCoursesIfChanged(
            Self.courses(Self.entry("CS1"), forceKeys: ["client:1151:CS1"]), semester: "1151"))
        #expect(try await coordinator.uploadCoursesIfChanged(list, semester: "1151", resend: true))
        coordinator.forgetUploads(semester: "1151")
        #expect(try await coordinator.uploadCoursesIfChanged(list, semester: "1151"))
        #expect(try await coordinator.uploadCoursesIfChanged(list, semester: "1142"))
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
            try await coordinator.uploadCoursesIfChanged(list, semester: "1151")
        }
        #expect(try await coordinator.uploadCoursesIfChanged(list, semester: "1151"))
        #expect(backend.uploads == 2)
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
}

