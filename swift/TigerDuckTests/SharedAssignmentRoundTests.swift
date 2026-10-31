import Defaults
import Foundation
import os
import Testing
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct SharedAssignmentRoundTests {
    private let shared = AssignmentRounds()

    @MainActor
    private final class Rounds {
        /// Callers that reached `sharedRound`, which decides whether to join before it first waits.
        var entered = 0
        var started: [String] = []
        var finished: [String] = []
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false

        func open() {
            isOpen = true
            waiting.forEach { $0.resume() }
            waiting = []
        }

        func run(_ name: String) async -> [SDAssignment] {
            started.append(name)
            if !isOpen { await withCheckedContinuation { waiting.append($0) } }
            finished.append(name)
            return []
        }
    }

    private func start(
        _ name: String, _ rounds: Rounds, signOuts: Int = 1, rechecks: Bool
    ) -> Task<Void, Never> {
        Task {
            rounds.entered += 1
            _ = await AppServiceBridge.sharedRound(signIn: .after(signOuts: signOuts), rechecks: rechecks, isCurrent: { true }, rounds: shared) {
                await rounds.run(name)
            }
        }
    }

    @Test("a round that starts while another runs for the account joins it")
    func roundsJoin() async throws {
        let rounds = Rounds()
        let launch = start("launch", rounds, rechecks: false)
        try await waitUntil { rounds.started == ["launch"] }
        let foreground = start("foreground", rounds, rechecks: false)
        let pullAfterPull = start("pull", rounds, rechecks: false)
        try await waitUntil { rounds.entered == 3 }
        rounds.open()
        _ = await (launch.value, foreground.value, pullAfterPull.value)
        #expect(rounds.started == ["launch"])
    }

    @Test("a pull waits out a round that skips submissions, then rechecks in its own")
    func pullRunsItsOwnRecheck() async throws {
        let rounds = Rounds()
        let launch = start("launch", rounds, rechecks: false)
        try await waitUntil { rounds.started == ["launch"] }
        let pull = start("pull", rounds, rechecks: true)
        try await waitUntil { rounds.entered == 2 }
        #expect(rounds.started == ["launch"])
        rounds.open()
        _ = await (launch.value, pull.value)
        #expect(rounds.started == ["launch", "pull"])
        #expect(rounds.finished == ["launch", "pull"])
    }

    @Test("a round that skips submissions joins a pull")
    func launchJoinsPull() async throws {
        let rounds = Rounds()
        let pull = start("pull", rounds, rechecks: true)
        try await waitUntil { rounds.started == ["pull"] }
        let foreground = start("foreground", rounds, rechecks: false)
        try await waitUntil { rounds.entered == 2 }
        rounds.open()
        _ = await (pull.value, foreground.value)
        #expect(rounds.started == ["pull"])
    }

    @MainActor
    private final class SignIn {
        var isCurrent = true
    }

    @Test("a round its account signed out of hands back the cache, not that account's list")
    func aRoundOutlivedBySignOutHandsBackTheCache() async {
        let signIn = SignIn()
        let departing = "departing-" + UUID().uuidString
        let due = Date(timeIntervalSince1970: 1_800_000_000)

        let shown = await AppServiceBridge.sharedRound(signIn: .after(signOuts: 1), rechecks: true, isCurrent: { signIn.isCurrent }, rounds: shared) {
            signIn.isCurrent = false
            return [SDAssignment(assignmentId: departing, courseNo: "CS1", courseName: "", title: "", dueDate: due)]
        }

        #expect(!shown.contains { $0.assignmentId == departing })
    }

    @Test("a caller that joined a round its account signed out of gets the cache too")
    func aJoinerOfARoundOutlivedBySignOutGetsTheCache() async throws {
        let rounds = Rounds()
        let signIn = SignIn()
        let departing = "departing-" + UUID().uuidString
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        let pull = Task {
            rounds.entered += 1
            _ = await AppServiceBridge.sharedRound(signIn: .after(signOuts: 1), rechecks: true, isCurrent: { signIn.isCurrent }, rounds: shared) {
                _ = await rounds.run("pull")
                return [SDAssignment(assignmentId: departing, courseNo: "CS1", courseName: "", title: "", dueDate: due)]
            }
        }
        try await waitUntil { rounds.started == ["pull"] }
        let joined = Task {
            rounds.entered += 1
            return await AppServiceBridge.sharedRound(signIn: .after(signOuts: 1), rechecks: false, isCurrent: { signIn.isCurrent }, rounds: shared) { [] }
        }
        try await waitUntil { rounds.entered == 2 }
        signIn.isCurrent = false
        rounds.open()

        #expect(await !joined.value.contains { $0.assignmentId == departing })
        await pull.value
    }

    @Test("a pull whose account signed out while it waited starts no round")
    func aWaiterOutlivedBySignOutStartsNoRound() async throws {
        let rounds = Rounds()
        let signIn = SignIn()
        let launch = start("launch", rounds, rechecks: false)
        try await waitUntil { rounds.started == ["launch"] }
        let pull = Task {
            rounds.entered += 1
            _ = await AppServiceBridge.sharedRound(signIn: .after(signOuts: 1), rechecks: true, isCurrent: { signIn.isCurrent }, rounds: shared) {
                await rounds.run("pull")
            }
        }
        try await waitUntil { rounds.entered == 2 }
        signIn.isCurrent = false
        rounds.open()
        _ = await (launch.value, pull.value)

        #expect(rounds.started == ["launch"])
    }

    @Test("the next account never joins the departing account's round")
    func roundsAreKeptPerSignIn() async throws {
        let rounds = Rounds()
        let departing = start("departing", rounds, signOuts: 1, rechecks: false)
        try await waitUntil { rounds.started == ["departing"] }
        let next = start("next", rounds, signOuts: 2, rechecks: false)
        try await waitUntil { rounds.started == ["departing", "next"] }
        rounds.open()
        _ = await (departing.value, next.value)
    }

    @MainActor
    private final class Folder {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedAssignmentRoundTests-\(UUID().uuidString)", isDirectory: true)
        lazy var cache = TestCache(
            cacheDir: root.appendingPathComponent("cache", isDirectory: true),
            persistentDir: root.appendingPathComponent("persistent", isDirectory: true)
        )

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private static let due = Date(timeIntervalSince1970: 1_800_000_000)
    private static let submittedAt = due - 600

    private static func newId() -> Int { Int.random(in: 100_000...999_999_999) }

    private static func handedIn(_ id: Int) -> MoodleSubmissionStatus {
        MoodleSubmissionStatus(assignId: id, submissionStatus: "submitted", gradingStatus: nil, submittedAt: submittedAt)
    }

    @discardableResult
    private func round(
        of id: Int, askedAt: ContinuousClock.Instant, in cache: TestCache, isCurrent: Bool = true
    ) -> Bool {
        AppServiceBridge.persistRound(
            [SDAssignment(assignmentId: String(id), courseNo: "CS3105301", courseName: "Data Structures", title: "HW 2",
                          dueDate: Self.due)],
            records: [], closed: [:], answered: [id: askedAt], account: "B11399001", fetchedAt: Self.due,
            assignments: cache.assignments, moodle: cache.moodle,
            rounds: shared, isCurrent: { isCurrent }
        )
    }

    private static func isCompleted(_ id: Int, in cache: TestCache) -> Bool? {
        cache.assignments.loadAssignments().first { $0.assignmentId == String(id) }?.isCompleted
    }

    @MainActor
    private final class Flag {
        var isSet = false
    }

    @Test("a status the page fetched reaches the cached assignment and tells Home, and the same one again writes nothing")
    func pageStatusIsWritten() async {
        let folder = Folder()
        let id = Self.newId()
        let now = ContinuousClock.now
        round(of: id, askedAt: now - .seconds(60), in: folder.cache)
        let store = folder.cache.assignments
        let before = store.revision

        #expect(await AppServiceBridge.takeSubmissionStatus(
            Self.handedIn(id), askedAt: now, assignments: store, rounds: shared, isCurrent: { true }
        ))

        let cached = store.loadAssignments().first { $0.assignmentId == String(id) }
        #expect(cached?.isCompleted == true)
        #expect(cached?.submittedAt == Self.submittedAt)
        let written = store.revision
        #expect(written != before)
        #expect(await !AppServiceBridge.takeSubmissionStatus(
            Self.handedIn(id), askedAt: now + .seconds(1), assignments: store, rounds: shared, isCurrent: { true }
        ))
        #expect(store.revision == written)
    }

    @Test("an extension the page fetched sets the cached due date, longer, shorter or taken back, and one before it is kept without moving it")
    func pageExtensionIsWritten() async {
        let folder = Folder()
        let id = Self.newId()
        let now = ContinuousClock.now
        round(of: id, askedAt: now - .seconds(60), in: folder.cache)
        var status = MoodleSubmissionStatus(
            assignId: id, submissionStatus: "new", gradingStatus: nil, submittedAt: nil, extensionDueDate: Self.due - 60
        )
        #expect(await AppServiceBridge.takeSubmissionStatus(status, askedAt: now, assignments: folder.cache.assignments, rounds: shared, isCurrent: { true }))
        let early = folder.cache.assignments.loadAssignments().first { $0.assignmentId == String(id) }
        #expect(early?.dueDate == Self.due)
        #expect(early?.extensionDueDate == Self.due - 60)

        for (step, extensionDate) in [Self.due + 2 * 86_400, Self.due + 86_400, nil].enumerated() {
            status.extensionDueDate = extensionDate
            #expect(await AppServiceBridge.takeSubmissionStatus(
                status, askedAt: now + .seconds(step + 1), assignments: folder.cache.assignments, rounds: shared, isCurrent: { true }
            ))
            let cached = folder.cache.assignments.loadAssignments().first { $0.assignmentId == String(id) }
            #expect(cached?.dueDate == extensionDate ?? Self.due)
            #expect(cached?.originalDueDate == Self.due)
            #expect(cached?.extensionDueDate == extensionDate)
            let event = folder.cache.assignments.loadCalendarEvents().first { $0.eventId == "moodle-\(id)" }
            #expect(event?.date == extensionDate ?? Self.due)
        }
    }

    @Test("an extension the page fetched past a closed assignment's cutoff has rounds ask about it again")
    func pageExtensionReopensAClosedAssignment() async {
        let folder = Folder()
        let id = Self.newId()
        let now = ContinuousClock.now
        let due = Date() - 2 * 86_400
        let closedAt = due + 86_400
        AppServiceBridge.persistRound(
            [SDAssignment(assignmentId: String(id), courseNo: "CS3105301", courseName: "Data Structures", title: "HW 2",
                          dueDate: due, cutoffDate: due + 3600)],
            records: [], closed: [String(id): closedAt, "1": closedAt], answered: [id: now - .seconds(60)],
            account: "B11399001", fetchedAt: closedAt,
            assignments: folder.cache.assignments, moodle: folder.cache.moodle, rounds: shared, isCurrent: { true }
        )

        #expect(await AppServiceBridge.takeSubmissionStatus(
            MoodleSubmissionStatus(
                assignId: id, submissionStatus: "new", gradingStatus: nil, submittedAt: nil,
                extensionDueDate: Date() + 86_400
            ),
            askedAt: now, assignments: folder.cache.assignments, rounds: shared, isCurrent: { true }
        ))

        #expect(folder.cache.assignments.loadClosedUnsubmittedAssignments() == ["1": closedAt])
    }

    @Test("a round running when the page's status comes is waited out, and its older answer does not replace it")
    func pageStatusWaitsOutARound() async throws {
        let folder = Folder()
        let cache = folder.cache
        let id = Self.newId()
        let pageAskedAt = ContinuousClock.now
        round(of: id, askedAt: pageAskedAt - .seconds(60), in: cache)
        let rounds = Rounds()
        let pull = Task {
            _ = await AppServiceBridge.sharedRound(signIn: .after(signOuts: 1), rechecks: true, isCurrent: { true }, rounds: shared) {
                _ = await rounds.run("pull")
                round(of: id, askedAt: pageAskedAt - .seconds(5), in: cache)
                return []
            }
        }
        try await waitUntil { rounds.started == ["pull"] }

        let asked = Flag()
        let page = Task {
            asked.isSet = true
            return await AppServiceBridge.takeSubmissionStatus(
                Self.handedIn(id), askedAt: pageAskedAt, assignments: cache.assignments, rounds: shared, isCurrent: { true }
            )
        }
        try await waitUntil { asked.isSet }
        #expect(Self.isCompleted(id, in: cache) == false)
        rounds.open()
        await pull.value

        #expect(await page.value)
        #expect(Self.isCompleted(id, in: cache) == true)
    }

    @Test("an answer asked for before the one the assignment has, a round's or another page's, is dropped")
    func olderAnswersAreDropped() async {
        let folder = Folder()
        let id = Self.newId()
        let now = ContinuousClock.now
        round(of: id, askedAt: now, in: folder.cache)

        #expect(await !AppServiceBridge.takeSubmissionStatus(
            Self.handedIn(id), askedAt: now - .seconds(1), assignments: folder.cache.assignments, rounds: shared, isCurrent: { true }
        ))
        #expect(Self.isCompleted(id, in: folder.cache) == false)

        #expect(await AppServiceBridge.takeSubmissionStatus(
            Self.handedIn(id), askedAt: now + .seconds(10), assignments: folder.cache.assignments, rounds: shared, isCurrent: { true }
        ))
        let reverted = MoodleSubmissionStatus(assignId: id, submissionStatus: "draft", gradingStatus: nil, submittedAt: nil)
        #expect(await !AppServiceBridge.takeSubmissionStatus(
            reverted, askedAt: now + .seconds(5), assignments: folder.cache.assignments, rounds: shared, isCurrent: { true }
        ))
        #expect(Self.isCompleted(id, in: folder.cache) == true)
    }

    @Test("a round that wrote nothing, its account signed out, leaves no time a page's answer has to beat")
    func unwrittenRoundKeepsNoTime() async {
        let folder = Folder()
        let id = Self.newId()
        let now = ContinuousClock.now
        round(of: id, askedAt: now - .seconds(60), in: folder.cache)
        #expect(!round(of: id, askedAt: now + .seconds(5), in: folder.cache, isCurrent: false))

        #expect(await AppServiceBridge.takeSubmissionStatus(
            Self.handedIn(id), askedAt: now, assignments: folder.cache.assignments, rounds: shared, isCurrent: { true }
        ))
    }

    @Test("a status fetched for an account that signed out while a round ran writes nothing")
    func pageStatusAfterSignOut() async throws {
        let folder = Folder()
        let cache = folder.cache
        let id = Self.newId()
        round(of: id, askedAt: .now - .seconds(60), in: cache)
        let rounds = Rounds()
        let signIn = SignIn()
        let launch = start("launch", rounds, rechecks: false)
        try await waitUntil { rounds.started == ["launch"] }

        let asked = Flag()
        let page = Task {
            asked.isSet = true
            return await AppServiceBridge.takeSubmissionStatus(
                Self.handedIn(id), askedAt: .now, assignments: cache.assignments, rounds: shared, isCurrent: { signIn.isCurrent }
            )
        }
        try await waitUntil { asked.isSet }
        signIn.isCurrent = false
        rounds.open()
        await launch.value

        #expect(await !page.value)
        #expect(Self.isCompleted(id, in: cache) == false)
    }

    @Test("the app's Moodle calls hand the page's status to the writer")
    func liveHandsStatusOn() async throws {
        let folder = Folder()
        let id = Self.newId()
        round(of: id, askedAt: .now - .seconds(60), in: folder.cache)

        MoodleCourseAPI.live.submissionFetched(
            Self.handedIn(id), .now, MoodleCacheContext(
                account: "B11399001", cache: folder.cache.moodle, assignments: folder.cache.assignments, isCurrent: { true }
            )
        )

        try await waitUntil(timeout: .seconds(10)) { Self.isCompleted(id, in: folder.cache) == true }
    }

    @MainActor
    private final class Sent {
        var requests: [PushAPI.AssignmentUploadRequest] = []
    }

    @Test("a status that changes the list sends it on for the reminders, with TigerSync on")
    func pageStatusIsUploaded() async {
        await withExclusiveRealDefaults {
            let saved = Defaults[.cloudSyncEnabled]
            let sent = Sent()
            Defaults[.cloudSyncEnabled] = true
            AppServiceBridge.assignmentUploader = { sent.requests.append($0) }
            defer {
                Defaults[.cloudSyncEnabled] = saved
                AppServiceBridge.assignmentUploader = nil
            }
            let folder = Folder()
            let id = Self.newId()
            round(of: id, askedAt: .now - .seconds(60), in: folder.cache)

            await AppServiceBridge.takeSubmissionStatus(
                Self.handedIn(id), askedAt: .now, assignments: folder.cache.assignments, rounds: shared, isCurrent: { true }
            )

            #expect(sent.requests.map { $0.assignments.map(\.moodleAssignmentId) } == [[id]])
            #expect(sent.requests.first?.assignments.first?.isSubmitted == true)
        }
    }
}
