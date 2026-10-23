import Defaults
import Foundation
import os
import Testing
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct SharedAssignmentRoundTests {
    @MainActor
    private final class Rounds {
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
        _ name: String, _ rounds: Rounds, generation: Int = 1, rechecks: Bool
    ) -> Task<Void, Never> {
        Task {
            _ = await AppServiceBridge.sharedRound(generation: generation, rechecks: rechecks, isCurrent: { true }) {
                await rounds.run(name)
            }
        }
    }

    @Test("a round that starts while another runs for the account joins it")
    func roundsJoin() async throws {
        AppServiceBridge.cancelAssignmentRound()
        let rounds = Rounds()
        let launch = start("launch", rounds, rechecks: false)
        try await waitUntil { rounds.started == ["launch"] }
        let foreground = start("foreground", rounds, rechecks: false)
        let pullAfterPull = start("pull", rounds, rechecks: false)
        try await Task.sleep(for: .milliseconds(20))
        rounds.open()
        _ = await (launch.value, foreground.value, pullAfterPull.value)
        #expect(rounds.started == ["launch"])
    }

    @Test("a pull waits out a round that skips submissions, then rechecks in its own")
    func pullRunsItsOwnRecheck() async throws {
        AppServiceBridge.cancelAssignmentRound()
        let rounds = Rounds()
        let launch = start("launch", rounds, rechecks: false)
        try await waitUntil { rounds.started == ["launch"] }
        let pull = start("pull", rounds, rechecks: true)
        try await Task.sleep(for: .milliseconds(20))
        #expect(rounds.started == ["launch"])
        rounds.open()
        _ = await (launch.value, pull.value)
        #expect(rounds.started == ["launch", "pull"])
        #expect(rounds.finished == ["launch", "pull"])
    }

    @Test("a round that skips submissions joins a pull")
    func launchJoinsPull() async throws {
        AppServiceBridge.cancelAssignmentRound()
        let rounds = Rounds()
        let pull = start("pull", rounds, rechecks: true)
        try await waitUntil { rounds.started == ["pull"] }
        let foreground = start("foreground", rounds, rechecks: false)
        try await Task.sleep(for: .milliseconds(20))
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
        AppServiceBridge.cancelAssignmentRound()
        let signIn = SignIn()
        let departing = "departing-" + UUID().uuidString
        let due = Date(timeIntervalSince1970: 1_800_000_000)

        let shown = await AppServiceBridge.sharedRound(generation: 1, rechecks: true, isCurrent: { signIn.isCurrent }) {
            signIn.isCurrent = false
            return [SDAssignment(assignmentId: departing, courseNo: "CS1", courseName: "", title: "", dueDate: due)]
        }

        #expect(!shown.contains { $0.assignmentId == departing })
    }

    @Test("a caller that joined a round its account signed out of gets the cache too")
    func aJoinerOfARoundOutlivedBySignOutGetsTheCache() async throws {
        AppServiceBridge.cancelAssignmentRound()
        let rounds = Rounds()
        let signIn = SignIn()
        let departing = "departing-" + UUID().uuidString
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        let pull = Task {
            _ = await AppServiceBridge.sharedRound(generation: 1, rechecks: true, isCurrent: { signIn.isCurrent }) {
                _ = await rounds.run("pull")
                return [SDAssignment(assignmentId: departing, courseNo: "CS1", courseName: "", title: "", dueDate: due)]
            }
        }
        try await waitUntil { rounds.started == ["pull"] }
        let joined = Task {
            await AppServiceBridge.sharedRound(generation: 1, rechecks: false, isCurrent: { signIn.isCurrent }) { [] }
        }
        try await Task.sleep(for: .milliseconds(20))
        signIn.isCurrent = false
        rounds.open()

        #expect(await !joined.value.contains { $0.assignmentId == departing })
        await pull.value
    }

    @Test("a pull whose account signed out while it waited starts no round")
    func aWaiterOutlivedBySignOutStartsNoRound() async throws {
        AppServiceBridge.cancelAssignmentRound()
        let rounds = Rounds()
        let signIn = SignIn()
        let launch = start("launch", rounds, rechecks: false)
        try await waitUntil { rounds.started == ["launch"] }
        let pull = Task {
            _ = await AppServiceBridge.sharedRound(generation: 1, rechecks: true, isCurrent: { signIn.isCurrent }) {
                await rounds.run("pull")
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        signIn.isCurrent = false
        rounds.open()
        _ = await (launch.value, pull.value)

        #expect(rounds.started == ["launch"])
    }

    @Test("the next account never joins the departing account's round")
    func roundsAreKeptPerSignIn() async throws {
        AppServiceBridge.cancelAssignmentRound()
        let rounds = Rounds()
        let departing = start("departing", rounds, generation: 1, rechecks: false)
        try await waitUntil { rounds.started == ["departing"] }
        let next = start("next", rounds, generation: 2, rechecks: false)
        try await waitUntil { rounds.started == ["departing", "next"] }
        rounds.open()
        _ = await (departing.value, next.value)
    }

    @MainActor
    private final class Folder {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedAssignmentRoundTests-\(UUID().uuidString)", isDirectory: true)
        lazy var cache = DataCache(
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
    private static func round(
        of id: Int, askedAt: ContinuousClock.Instant, in cache: DataCache, isCurrent: Bool = true
    ) -> Bool {
        AppServiceBridge.persistRound(
            [SDAssignment(assignmentId: String(id), courseNo: "CS3105301", courseName: "Data Structures", title: "HW 2",
                          dueDate: due)],
            records: [], closed: [:], answered: [id: askedAt], account: "B11399001", fetchedAt: due, cache: cache,
            isCurrent: { isCurrent }
        )
    }

    private static func isCompleted(_ id: Int, in cache: DataCache) -> Bool? {
        cache.loadAssignments().first { $0.assignmentId == String(id) }?.isCompleted
    }

    @MainActor
    private final class Flag {
        var isSet = false
    }

    @Test("a status the page fetched reaches the cached assignment and tells Home, and the same one again writes nothing")
    func pageStatusIsWritten() async {
        AppServiceBridge.cancelAssignmentRound()
        let folder = Folder()
        let id = Self.newId()
        let now = ContinuousClock.now
        Self.round(of: id, askedAt: now - .seconds(60), in: folder.cache)
        let center = NotificationCenter()
        let heard = OSAllocatedUnfairLock(initialState: 0)
        let observer = center.addObserver(forName: AppConstants.dataDidUpdate, object: nil, queue: nil) { _ in
            heard.withLock { $0 += 1 }
        }
        defer { center.removeObserver(observer) }

        #expect(await AppServiceBridge.takeSubmissionStatus(
            Self.handedIn(id), askedAt: now, cache: folder.cache, isCurrent: { true }, notifying: center
        ))

        let cached = folder.cache.loadAssignments().first { $0.assignmentId == String(id) }
        #expect(cached?.isCompleted == true)
        #expect(cached?.submittedAt == Self.submittedAt)
        #expect(heard.withLock { $0 } == 1)
        #expect(await !AppServiceBridge.takeSubmissionStatus(
            Self.handedIn(id), askedAt: now + .seconds(1), cache: folder.cache, isCurrent: { true }, notifying: center
        ))
        #expect(heard.withLock { $0 } == 1)
    }

    @Test("a round running when the page's status comes is waited out, and its older answer does not replace it")
    func pageStatusWaitsOutARound() async throws {
        AppServiceBridge.cancelAssignmentRound()
        let folder = Folder()
        let cache = folder.cache
        let id = Self.newId()
        let pageAskedAt = ContinuousClock.now
        Self.round(of: id, askedAt: pageAskedAt - .seconds(60), in: cache)
        let rounds = Rounds()
        let pull = Task {
            _ = await AppServiceBridge.sharedRound(generation: 1, rechecks: true, isCurrent: { true }) {
                _ = await rounds.run("pull")
                Self.round(of: id, askedAt: pageAskedAt - .seconds(5), in: cache)
                return []
            }
        }
        try await waitUntil { rounds.started == ["pull"] }

        let asked = Flag()
        let page = Task {
            asked.isSet = true
            return await AppServiceBridge.takeSubmissionStatus(
                Self.handedIn(id), askedAt: pageAskedAt, cache: cache, isCurrent: { true }
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
        AppServiceBridge.cancelAssignmentRound()
        let folder = Folder()
        let id = Self.newId()
        let now = ContinuousClock.now
        Self.round(of: id, askedAt: now, in: folder.cache)

        #expect(await !AppServiceBridge.takeSubmissionStatus(
            Self.handedIn(id), askedAt: now - .seconds(1), cache: folder.cache, isCurrent: { true }
        ))
        #expect(Self.isCompleted(id, in: folder.cache) == false)

        #expect(await AppServiceBridge.takeSubmissionStatus(
            Self.handedIn(id), askedAt: now + .seconds(10), cache: folder.cache, isCurrent: { true }
        ))
        let reverted = MoodleSubmissionStatus(assignId: id, submissionStatus: "draft", gradingStatus: nil, submittedAt: nil)
        #expect(await !AppServiceBridge.takeSubmissionStatus(
            reverted, askedAt: now + .seconds(5), cache: folder.cache, isCurrent: { true }
        ))
        #expect(Self.isCompleted(id, in: folder.cache) == true)
    }

    @Test("a round that wrote nothing, its account signed out, leaves no time a page's answer has to beat")
    func unwrittenRoundKeepsNoTime() async {
        AppServiceBridge.cancelAssignmentRound()
        let folder = Folder()
        let id = Self.newId()
        let now = ContinuousClock.now
        Self.round(of: id, askedAt: now - .seconds(60), in: folder.cache)
        #expect(!Self.round(of: id, askedAt: now + .seconds(5), in: folder.cache, isCurrent: false))

        #expect(await AppServiceBridge.takeSubmissionStatus(
            Self.handedIn(id), askedAt: now, cache: folder.cache, isCurrent: { true }
        ))
    }

    @Test("a status fetched for an account that signed out while a round ran writes nothing")
    func pageStatusAfterSignOut() async throws {
        AppServiceBridge.cancelAssignmentRound()
        let folder = Folder()
        let cache = folder.cache
        let id = Self.newId()
        Self.round(of: id, askedAt: .now - .seconds(60), in: cache)
        let rounds = Rounds()
        let signIn = SignIn()
        let launch = start("launch", rounds, rechecks: false)
        try await waitUntil { rounds.started == ["launch"] }

        let asked = Flag()
        let page = Task {
            asked.isSet = true
            return await AppServiceBridge.takeSubmissionStatus(
                Self.handedIn(id), askedAt: .now, cache: cache, isCurrent: { signIn.isCurrent }
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
        AppServiceBridge.cancelAssignmentRound()
        let folder = Folder()
        let id = Self.newId()
        Self.round(of: id, askedAt: .now - .seconds(60), in: folder.cache)

        MoodleCourseAPI.live.submissionFetched(
            Self.handedIn(id), .now, MoodleCacheContext(account: "B11399001", cache: folder.cache, isCurrent: { true })
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
            AppServiceBridge.cancelAssignmentRound()
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
            Self.round(of: id, askedAt: .now - .seconds(60), in: folder.cache)

            await AppServiceBridge.takeSubmissionStatus(
                Self.handedIn(id), askedAt: .now, cache: folder.cache, isCurrent: { true }
            )

            #expect(sent.requests.map { $0.assignments.map(\.moodleAssignmentId) } == [[id]])
            #expect(sent.requests.first?.assignments.first?.isSubmitted == true)
        }
    }
}
