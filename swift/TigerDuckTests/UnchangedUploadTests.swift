import Foundation
import os
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

    private static func courses(_ entries: PushAPI.CourseUploadEntry..., adds: [String] = [])
        -> PushAPI.CourseUploadRequest {
        PushAPI.CourseUploadRequest(
            courses: entries, handAddedCourses: adds.isEmpty ? nil : adds.map { PushAPI.CourseAdd(courseKey: $0, hlc: 1) }
        )
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
        let resend = SendLedger.Resend.after(PushCoordinator.unchangedUploadInterval)
        #expect(SendLedger.isDue(accepted: nil, fingerprint: "a", resend: resend, now: now))
        #expect(SendLedger.isDue(accepted: ("b", now - 60), fingerprint: "a", resend: resend, now: now))
        #expect(!SendLedger.isDue(accepted: ("a", now - 60), fingerprint: "a", resend: resend, now: now))
        #expect(SendLedger.isDue(accepted: ("a", now - 6 * 3600), fingerprint: "a", resend: resend, now: now))
    }

    @Test("A fingerprint is a SHA-256 of the body's JSON with sorted keys, the same in every launch")
    func fingerprintIsStable() {
        #expect(SendLedger.fingerprint(of: ["b": 1, "a": 2])
            == "d3626ac30a87e6f7a6428233b3c68299976865fa5508e4267c5415c76af7a772")
    }

    @Test("The same courses in another order are the same list; a changed room is not")
    func fingerprintIgnoresOrderOnly() {
        let one = PushCoordinator.fingerprint(of: Self.courses(Self.entry("CS1"), Self.entry("CS2")))
        let reordered = PushCoordinator.fingerprint(of: Self.courses(Self.entry("CS2"), Self.entry("CS1")))
        let moved = PushCoordinator.fingerprint(of: Self.courses(Self.entry("CS1", room: "IB-101"), Self.entry("CS2")))
        #expect(one == reordered)
        #expect(one != moved)
    }

    @Test("The courses an upload adds by hand leave its list the same, as once it lands the backend holds that list")
    func handAddsLeaveTheListAlone() {
        let plain = PushCoordinator.fingerprint(of: Self.courses(Self.entry("CS1")))
        let adding = PushCoordinator.fingerprint(of: Self.courses(Self.entry("CS1"), adds: ["client:1151:CS1"]))
        #expect(plain == adding)
    }

    @Test("A roster names its terms in roster_terms, and is another list than the same courses sent without")
    func rosterTermsGoUpAndCount() throws {
        let plain = Self.courses(Self.entry("CS1"))
        var roster = plain
        roster.completeRosterTerms = ["1151"]

        let sent = try JSONSerialization.jsonObject(with: JSONEncoder().encode(roster)) as? [String: Any]
        let sentPlain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any]

        #expect(sent?["roster_terms"] as? [String] == ["1151"])
        #expect(sentPlain?["roster_terms"] == nil)
        #expect(PushCoordinator.fingerprint(of: roster) != PushCoordinator.fingerprint(of: plain))
    }

    @Test("A roster the backend asks for goes again unchanged, roster_terms and all")
    func requestedRosterGoesAgainUnchanged() async throws {
        let backend = Backend()
        backend.answer(times: 2)
        let coordinator = backend.makeCoordinator()
        let roster = SchoolDataUploader.courseUploadRequest(
            [SDCourse(courseNo: "CS1", courseName: "CS1")], semester: "1151", rosterTerms: ["1151"]
        )

        #expect(try await coordinator.uploadCoursesIfChanged(roster, semester: "1151", for: testSignIn))
        #expect(try await !coordinator.uploadCoursesIfChanged(roster, semester: "1151", for: testSignIn))
        #expect(try await coordinator.uploadCoursesIfChanged(roster, semester: "1151", resend: true, for: testSignIn))
        let sent = SettingsAPIStub.requests(for: backend.uploadURL).map { request in
            (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
        }
        #expect(sent.map { $0?["roster_terms"] as? [String] } == [["1151"], ["1151"]])
    }

    @Test("An unchanged list is skipped; an add, a resend, a reset and another term still go")
    func unchangedListIsSkipped() async throws {
        let backend = Backend()
        backend.answer(times: 5)
        let coordinator = backend.makeCoordinator()
        let list = Self.courses(Self.entry("CS1"))

        #expect(try await coordinator.uploadCoursesIfChanged(list, semester: "1151", for: testSignIn))
        #expect(try await !coordinator.uploadCoursesIfChanged(list, semester: "1151", for: testSignIn))
        #expect(backend.uploads == 1)

        #expect(try await coordinator.uploadCoursesIfChanged(
            Self.courses(Self.entry("CS1"), adds: ["client:1151:CS1"]), semester: "1151", addedAt: Date(),
            for: testSignIn))
        #expect(try await coordinator.uploadCoursesIfChanged(list, semester: "1151", resend: true, for: testSignIn))
        coordinator.forgetUploads(semester: "1151")
        #expect(try await coordinator.uploadCoursesIfChanged(list, semester: "1151", for: testSignIn))
        #expect(try await coordinator.uploadCoursesIfChanged(list, semester: "1142", for: testSignIn))
        #expect(backend.uploads == 5)
    }

    @MainActor
    private final class Clock {
        var now = Date()
    }

    @Test("A list the server refused waits a minute from the answer, and another list does not")
    func refusedListWaitsAMinute() async throws {
        let backend = Backend()
        backend.answer(status: 503)
        backend.answer()
        backend.answer(status: 503)
        backend.answer()
        let coordinator = backend.makeCoordinator()
        let clock = Clock()
        coordinator.ledger.clock = { clock.now }
        let list = Self.courses(Self.entry("CS1"))

        await #expect(throws: PushAPIError.self) {
            try await coordinator.uploadCoursesIfChanged(list, semester: "1151", for: testSignIn)
        }
        clock.now += 59
        #expect(try await !coordinator.uploadCoursesIfChanged(list, semester: "1151", for: testSignIn))
        #expect(coordinator.holdsUnsentCourseUploads)
        clock.now += 1
        #expect(try await coordinator.uploadCoursesIfChanged(list, semester: "1151", for: testSignIn))

        await #expect(throws: PushAPIError.self) {
            try await coordinator.uploadCoursesIfChanged(Self.courses(Self.entry("CS2")), semester: "1151", for: testSignIn)
        }
        #expect(try await coordinator.uploadCoursesIfChanged(Self.courses(Self.entry("CS3")), semester: "1151", for: testSignIn))
        #expect(backend.uploads == 4)
    }

    @Test("A refused list held back after the accepted one was resent still counts as unsent")
    func heldBackListStaysUnsent() async throws {
        let backend = Backend()
        backend.answer()
        backend.answer(status: 422)
        let coordinator = backend.makeCoordinator()
        let clock = Clock()
        coordinator.ledger.clock = { clock.now }
        let accepted = Self.courses(Self.entry("CS1"))
        let refused = Self.courses(Self.entry("CS2"))

        #expect(try await coordinator.uploadCoursesIfChanged(accepted, semester: "1151", for: testSignIn))
        await #expect(throws: PushAPIError.self) {
            try await coordinator.uploadCoursesIfChanged(refused, semester: "1151", for: testSignIn)
        }
        #expect(try await !coordinator.uploadCoursesIfChanged(accepted, semester: "1151", for: testSignIn))
        #expect(try await !coordinator.uploadCoursesIfChanged(refused, semester: "1151", for: testSignIn))

        #expect(coordinator.holdsUnsentCourseUploads)
        #expect(backend.uploads == 2)
    }

    @Test("A list answered 401 goes again at once, as the retry after signing in sends it")
    func unauthorizedListIsNotHeldBack() async throws {
        let backend = Backend()
        backend.answer(status: 401)
        backend.answer()
        let coordinator = backend.makeCoordinator()
        let clock = Clock()
        coordinator.ledger.clock = { clock.now }
        let list = Self.courses(Self.entry("CS1"))

        await #expect(throws: PushAPIError.self) {
            try await coordinator.uploadCoursesIfChanged(list, semester: "1151", for: testSignIn)
        }
        clock.now += 1
        #expect(try await coordinator.uploadCoursesIfChanged(list, semester: "1151", for: testSignIn))
        #expect(backend.uploads == 2)
    }

    @Test("A refused list still goes at once when resent, with an add, after a reset, or when it never reached the server")
    func refusalHoldsOnlyAnAnsweredList() async throws {
        let backend = Backend()
        backend.answer(status: 422)
        backend.answer(status: 422)
        backend.answer(times: 2)
        let coordinator = backend.makeCoordinator()
        coordinator.ledger.clock = { Date(timeIntervalSince1970: 1_800_000_000) }
        let list = Self.courses(Self.entry("CS1"))

        await #expect(throws: PushAPIError.self) {
            try await coordinator.uploadCoursesIfChanged(list, semester: "1151", for: testSignIn)
        }
        await #expect(throws: PushAPIError.self) {
            try await coordinator.uploadCoursesIfChanged(list, semester: "1151", resend: true, for: testSignIn)
        }
        #expect(try await coordinator.uploadCoursesIfChanged(
            Self.courses(Self.entry("CS1"), adds: ["client:1151:CS1"]), semester: "1151", addedAt: Date(),
            for: testSignIn))
        coordinator.forgetUploads(semester: "1151")
        #expect(try await coordinator.uploadCoursesIfChanged(list, semester: "1151", for: testSignIn))
        #expect(backend.uploads == 4)

        let key = SendLedger.Channel.courses("1142")
        _ = try? await coordinator.ledger.send(key, fingerprint: "1", resend: .after(PushCoordinator.unchangedUploadInterval)) {
            throw URLError(.notConnectedToInternet)
        }
        #expect(try await coordinator.ledger.send(key, fingerprint: "1", resend: .after(PushCoordinator.unchangedUploadInterval)) {} == .sent)
    }

    @Test("Cancelling an upload's caller stops its send, or skips it while it waits its turn, and records no failure")
    func cancelledCallerStopsTheUpload() async throws {
        let coordinator = Backend().makeCoordinator()
        let key = SendLedger.Channel.courses("1151")
        let sent = OSAllocatedUnfairLock(initialState: [Int]())
        let release = ManualSleeper()
        let first = Task {
            try await coordinator.ledger.send(key, fingerprint: "1", resend: .always) {
                sent.withLock { $0.append(1) }
                await release.sleep(for: .zero)
                try await Task.sleep(for: .seconds(30))
            }
        }
        try await release.waitUntilArmed()
        let second = Task {
            try await coordinator.ledger.send(key, fingerprint: "2", resend: .always) {
                sent.withLock { $0.append(2) }
            }
        }
        second.cancel()
        await release.fire()
        first.cancel()

        let ended = OSAllocatedUnfairLock(initialState: false)
        let watcher = Task {
            _ = try? await first.value
            _ = try? await second.value
            ended.withLock { $0 = true }
        }
        try await waitUntil(timeout: .seconds(10)) { ended.withLock { $0 } }
        await watcher.value

        await #expect(throws: CancellationError.self) { try await first.value }
        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(sent.withLock { $0 } == [1])
        #expect(!coordinator.holdsUnsentCourseUploads)
    }

    @Test("A course list the server refused counts as unsent until a list of that term goes up or a sign-out forgets it")
    func refusedListIsUnsent() async throws {
        let backend = Backend()
        backend.answer(status: 503)
        backend.answer()
        backend.answer(status: 503)
        let coordinator = backend.makeCoordinator()
        let clock = Clock()
        coordinator.ledger.clock = { clock.now }
        let list = Self.courses(Self.entry("CS1"))
        #expect(!coordinator.holdsUnsentCourseUploads)

        await #expect(throws: PushAPIError.self) {
            try await coordinator.uploadCoursesIfChanged(list, semester: "1151", for: testSignIn)
        }
        #expect(coordinator.holdsUnsentCourseUploads)
        clock.now += SendLedger.refusedBodyHoldInterval
        #expect(try await coordinator.uploadCoursesIfChanged(list, semester: "1151", for: testSignIn))
        #expect(!coordinator.holdsUnsentCourseUploads)

        await #expect(throws: PushAPIError.self) {
            try await coordinator.uploadCoursesIfChanged(Self.courses(Self.entry("CS2")), semester: "1151", for: testSignIn)
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

        #expect(try await coordinator.uploadCoursesIfChanged(taken, semester: "1151", for: testSignIn))
        await #expect(throws: PushAPIError.self) {
            try await coordinator.uploadCoursesIfChanged(Self.courses(Self.entry("CS2")), semester: "1151", for: testSignIn)
        }
        #expect(coordinator.holdsUnsentCourseUploads)
        #expect(try await !coordinator.uploadCoursesIfChanged(taken, semester: "1151", for: testSignIn))

        #expect(!coordinator.holdsUnsentCourseUploads)
        #expect(backend.uploads == 2)
    }

    @Test("A course upload cancelled, or failing after its account signed out, leaves nothing unsent")
    func cancelledOrSignedOutFailureIsNotUnsent() async {
        let coordinator = Backend().makeCoordinator()
        let key = SendLedger.Channel.courses("1151")
        _ = try? await coordinator.ledger.send(key, fingerprint: "1", resend: .after(PushCoordinator.unchangedUploadInterval)) {
            throw CancellationError()
        }
        _ = try? await coordinator.ledger.send(key, fingerprint: "1", resend: .after(PushCoordinator.unchangedUploadInterval)) {
            throw URLError(.cancelled)
        }
        #expect(!coordinator.holdsUnsentCourseUploads)

        let account = AccountSession()
        _ = try? await coordinator.ledger.send(
            key, fingerprint: "1", resend: .after(PushCoordinator.unchangedUploadInterval), for: account.signIns.currentSignIn
        ) {
            account.endSignIn()
            throw URLError(.timedOut)
        }
        #expect(!coordinator.holdsUnsentCourseUploads)

        _ = try? await coordinator.ledger.send(key, fingerprint: "1", resend: .after(PushCoordinator.unchangedUploadInterval)) {
            throw URLError(.timedOut)
        }
        #expect(coordinator.holdsUnsentCourseUploads)
    }

    @Test("A course list out again unchanged, as a resend of what the server took, is not unsent")
    func unchangedResendInFlightIsNotUnsent() async throws {
        let coordinator = Backend().makeCoordinator()
        let sends = Sends()
        let key = SendLedger.Channel.courses("1151")
        #expect(try await coordinator.ledger.send(key, fingerprint: "1", resend: .after(PushCoordinator.unchangedUploadInterval)) {
            await sends.send(1)
        } == .sent)

        sends.holds = true
        let resend = Task {
            try await coordinator.ledger.send(key, fingerprint: "1", resend: .always) {
                await sends.send(1)
            }
        }
        try await waitUntil { sends.isParked }
        #expect(!coordinator.holdsUnsentCourseUploads)
        sends.release()
        #expect(try await resend.value == .sent)
    }

    @Test("A course list counts as unsent while it is out, and an assignment list does not")
    func courseListInFlightIsUnsent() async throws {
        let coordinator = Backend().makeCoordinator()
        let sends = Sends()
        sends.holds = true
        let assignments = Task {
            try await coordinator.ledger.send(SendLedger.Channel.assignments, fingerprint: "1", resend: .after(PushCoordinator.unchangedUploadInterval)) {
                await sends.send(1)
            }
        }
        try await waitUntil { sends.isParked }
        #expect(!coordinator.holdsUnsentCourseUploads)
        sends.release()
        _ = try await assignments.value

        sends.holds = true
        let courses = Task {
            try await coordinator.ledger.send(SendLedger.Channel.courses("1151"), fingerprint: "2", resend: .after(PushCoordinator.unchangedUploadInterval)) {
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
    func uploadAcrossAForgetRecordsNothing() async throws {
        let ledger = SendLedger()
        let channel = SendLedger.Channel.courses("1151")

        #expect(try await ledger.send(channel, fingerprint: "1", resend: .never) {
            ledger.forget(channel)
        } == .sent)
        #expect(!ledger.accepts(channel, fingerprint: "1"))
        #expect(try await ledger.send(channel, fingerprint: "1", resend: .never) {} == .sent)
        #expect(ledger.accepts(channel, fingerprint: "1"))
    }

    @Test("A reset of one term leaves other lists in flight free to record; a sign-out stops them all")
    func forgetsReachOnlyTheirLists() async throws {
        let ledger = SendLedger()
        let reset = SendLedger.Channel.courses("1151")
        let other = SendLedger.Channel.courses("1142")

        _ = try await ledger.send(other, fingerprint: "1", resend: .never) { ledger.forget(reset) }
        _ = try await ledger.send(SendLedger.Channel.assignments, fingerprint: "2", resend: .never) {
            ledger.forget(reset)
        }
        #expect(ledger.accepts(other, fingerprint: "1"))
        #expect(ledger.accepts(SendLedger.Channel.assignments, fingerprint: "2"))

        _ = try await ledger.send(other, fingerprint: "3", resend: .never) { ledger.forget(nil) }
        #expect(!ledger.accepts(other, fingerprint: "3"))
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
        let key = SendLedger.Channel.courses("1151")
        #expect(try await coordinator.ledger.send(key, fingerprint: "1", resend: .after(PushCoordinator.unchangedUploadInterval)) { await sends.send(1) } == .sent)

        sends.holds = true
        let edit = Task { try await coordinator.ledger.send(key, fingerprint: "2", resend: .after(PushCoordinator.unchangedUploadInterval)) { await sends.send(2) } }
        try await waitUntil { sends.isParked }
        let undo = Task { try await coordinator.ledger.send(key, fingerprint: "1", resend: .after(PushCoordinator.unchangedUploadInterval)) { await sends.send(1) } }
        for _ in 0..<50 { await Task.yield() }
        #expect(sends.isParked)
        #expect(coordinator.holdsUnsentCourseUploads)
        sends.release()

        #expect(try await edit.value == .sent)
        #expect(try await undo.value == .sent)
        #expect(sends.sent == [1, 2, 1])
        #expect(!coordinator.holdsUnsentCourseUploads)
    }

    @Test("An upload queued behind another is dropped if its account signs out while it waits")
    func queuedUploadSkipsAfterSignOut() async throws {
        let coordinator = Backend().makeCoordinator()
        let sends = Sends()
        let key = SendLedger.Channel.assignments
        let account = AccountSession()

        sends.holds = true
        let first = Task {
            try await coordinator.ledger.send(key, fingerprint: "1", resend: .after(PushCoordinator.unchangedUploadInterval)) {
                await sends.send(1)
            }
        }
        try await waitUntil { sends.isParked }
        let signIn = account.signIns.currentSignIn
        let queued = Task {
            try await coordinator.ledger.send(key, fingerprint: "2", resend: .always, for: signIn) {
                await sends.send(2)
            }
        }
        account.endSignIn()
        sends.release()

        #expect(try await first.value == .sent)
        #expect(try await queued.value == .skipped)
        #expect(sends.sent == [1])
    }
}
