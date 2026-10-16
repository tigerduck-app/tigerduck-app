import Foundation
import os
import Testing
@testable import TigerDuck

/// One round at a time, and how a status an assignment's page fetched joins the rounds' writes,
/// into a cache in a folder of its own. Every id here is made up.
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

    /// A Home pull asks Moodle about every submission, long enough to sign out meanwhile.
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

    /// A pull waits out a round that skips submissions, then runs its own; not once its account
    /// has signed out, when the next account's round may already be running.
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

    // MARK: - A status the assignment's page fetched

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

    /// The answers the bridge keeps last for an assignment outlive a test, so each takes its own.
    private static func newId() -> Int { Int.random(in: 100_000...999_999_999) }

    private static func handedIn(_ id: Int) -> MoodleSubmissionStatus {
        MoodleSubmissionStatus(assignId: id, submissionStatus: "submitted", gradingStatus: nil, submittedAt: submittedAt)
    }

    /// A round that asked Moodle about `id` at `askedAt` and heard it was not handed in.
    @discardableResult
    private static func round(of id: Int, askedAt: Date, in cache: DataCache) -> Bool {
        AppServiceBridge.persistRound(
            [SDAssignment(assignmentId: String(id), courseNo: "CS3105301", courseName: "Data Structures", title: "HW 2",
                          dueDate: due)],
            records: [], closed: [:], answered: [id], account: "B11399001", fetchedAt: askedAt, cache: cache,
            isCurrent: { true }
        )
    }

    private static func isCompleted(_ id: Int, in cache: DataCache) -> Bool? {
        cache.loadAssignments().first { $0.assignmentId == String(id) }?.isCompleted
    }

    @Test("a status the page fetched reaches the cached assignment and tells Home, and the same one again writes nothing")
    func pageStatusIsWritten() async {
        AppServiceBridge.cancelAssignmentRound()
        let folder = Folder()
        let id = Self.newId()
        let now = Date()
        Self.round(of: id, askedAt: now - 60, in: folder.cache)
        let heard = OSAllocatedUnfairLock(initialState: 0)
        let observer = NotificationCenter.default.addObserver(
            forName: AppConstants.dataDidUpdate, object: nil, queue: nil
        ) { _ in heard.withLock { $0 += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }

        #expect(await AppServiceBridge.takeSubmissionStatus(
            Self.handedIn(id), askedAt: now, cache: folder.cache, isCurrent: { true }
        ))

        let cached = folder.cache.loadAssignments().first { $0.assignmentId == String(id) }
        #expect(cached?.isCompleted == true)
        #expect(cached?.submittedAt == Self.submittedAt)
        #expect(heard.withLock { $0 } >= 1)
        #expect(await !AppServiceBridge.takeSubmissionStatus(
            Self.handedIn(id), askedAt: now + 1, cache: folder.cache, isCurrent: { true }
        ))
    }

    @Test("a round running when the page's status comes is waited out, and its older answer does not replace it")
    func pageStatusWaitsOutARound() async throws {
        AppServiceBridge.cancelAssignmentRound()
        let folder = Folder()
        let cache = folder.cache
        let id = Self.newId()
        let pageAskedAt = Date()
        Self.round(of: id, askedAt: pageAskedAt - 60, in: cache)
        let rounds = Rounds()
        // Asked Moodle before the page did, and writes once it ends.
        let pull = Task {
            _ = await AppServiceBridge.sharedRound(generation: 1, rechecks: true, isCurrent: { true }) {
                _ = await rounds.run("pull")
                Self.round(of: id, askedAt: pageAskedAt - 5, in: cache)
                return []
            }
        }
        try await waitUntil { rounds.started == ["pull"] }

        let page = Task {
            await AppServiceBridge.takeSubmissionStatus(Self.handedIn(id), askedAt: pageAskedAt, cache: cache, isCurrent: { true })
        }
        try await Task.sleep(for: .milliseconds(20))
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
        let now = Date()
        Self.round(of: id, askedAt: now, in: folder.cache)

        #expect(await !AppServiceBridge.takeSubmissionStatus(
            Self.handedIn(id), askedAt: now - 1, cache: folder.cache, isCurrent: { true }
        ))
        #expect(Self.isCompleted(id, in: folder.cache) == false)

        #expect(await AppServiceBridge.takeSubmissionStatus(
            Self.handedIn(id), askedAt: now + 10, cache: folder.cache, isCurrent: { true }
        ))
        let reverted = MoodleSubmissionStatus(assignId: id, submissionStatus: "draft", gradingStatus: nil, submittedAt: nil)
        #expect(await !AppServiceBridge.takeSubmissionStatus(
            reverted, askedAt: now + 5, cache: folder.cache, isCurrent: { true }
        ))
        #expect(Self.isCompleted(id, in: folder.cache) == true)
    }

    @Test("a status fetched for an account that signed out while a round ran writes nothing")
    func pageStatusAfterSignOut() async throws {
        AppServiceBridge.cancelAssignmentRound()
        let folder = Folder()
        let cache = folder.cache
        let id = Self.newId()
        Self.round(of: id, askedAt: Date() - 60, in: cache)
        let rounds = Rounds()
        let signIn = SignIn()
        let launch = start("launch", rounds, rechecks: false)
        try await waitUntil { rounds.started == ["launch"] }

        let page = Task {
            await AppServiceBridge.takeSubmissionStatus(
                Self.handedIn(id), askedAt: Date(), cache: cache, isCurrent: { signIn.isCurrent }
            )
        }
        try await Task.sleep(for: .milliseconds(20))
        signIn.isCurrent = false
        rounds.open()
        await launch.value

        #expect(await !page.value)
        #expect(Self.isCompleted(id, in: cache) == false)
    }
}
