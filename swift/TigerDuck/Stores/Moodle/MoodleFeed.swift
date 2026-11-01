import Foundation
import Observation

struct MoodleCacheContext {
    let account: String
    let cache: MoodleFiles
    var assignments: AssignmentStore = .shared
    let signIn: SignIn
    var now: () -> Date = { Date() }

    static func signedIn(_ authService: AuthService, for signIn: SignIn, cache: MoodleFiles = .shared) -> MoodleCacheContext? {
        guard let account = authService.storedStudentId else { return nil }
        return MoodleCacheContext(account: account, cache: cache, signIn: signIn)
    }

    func save<Value: Codable>(_ value: Value, fetchedAt: Date, name: String) {
        cache.saveMoodleData(value, fetchedAt: fetchedAt, name: name, account: account, for: signIn)
    }
}

@Observable
@MainActor
final class MoodleFeed<Value: Codable & Sendable> {
    let ttl: TimeInterval
    private(set) var value: Value?
    private(set) var fetchedAt: Date?
    private(set) var isRefreshing = false
    private(set) var status: ServerStatus = .unknown
    private(set) var failure: (any Error)?
    private(set) var failureCount = 0

    private struct Copy {
        let name: String
        let context: MoodleCacheContext

        func save(_ value: Value, fetchedAt: Date) {
            context.save(value, fetchedAt: fetchedAt, name: name)
        }
    }

    @ObservationIgnored private let copy: Copy
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var edits = EditToken()

    private var context: MoodleCacheContext { copy.context }

    init(cacheName: String, ttl: TimeInterval, context: MoodleCacheContext) {
        copy = Copy(name: cacheName, context: context)
        self.ttl = ttl
        if let cached = context.cache.loadMoodleData(Value.self, name: cacheName, account: context.account) {
            value = cached.value
            fetchedAt = cached.fetchedAt
            if MoodleRefreshTimer.wait(fetchedAt: cached.fetchedAt, lastTry: nil, ttl: ttl, now: context.now()) > 0 {
                status = .ok
            }
        }
    }

    func refresh(_ fetch: @escaping @Sendable () async throws -> Value) async {
        if let running {
            await running.value
            return
        }
        let task = Task { await run(fetch) }
        running = task
        await task.value
        if running == task { running = nil }
    }

    func refreshAfterSiteChange(_ fetch: @escaping @Sendable () async throws -> Value) async {
        if let earlier = running {
            await earlier.value
            if running == earlier { running = nil }
        }
        await refresh(fetch)
    }

    func applyDerived(_ change: (inout Value) -> Void) {
        guard var changed = value, let fetchedAt, context.signIn.isCurrent else { return }
        change(&changed)
        value = changed
        copy.save(changed, fetchedAt: fetchedAt)
    }

    func applyUserEdit(_ change: (inout Value) -> Void) {
        guard value != nil, fetchedAt != nil, context.signIn.isCurrent else { return }
        edits.recordUserEdit()
        applyDerived(change)
    }

    private func run(_ fetch: @Sendable () async throws -> Value) async {
        isRefreshing = true
        defer { isRefreshing = false }
        let started = edits
        do {
            let fresh = try await fetch()
            guard context.signIn.isCurrent else { return }
            status = .ok
            failure = nil
            guard !edits.editedSince(started) else { return }
            let now = context.now()
            value = fresh
            fetchedAt = now
            copy.save(fresh, fetchedAt: now)
        } catch {
            guard context.signIn.isCurrent else { return }
            status = .failed
            failure = error
            failureCount += 1
        }
    }
}

extension AssignmentAnswers {
    static func persistRound(
        _ assignments: [SDAssignment],
        records: [MoodleAssignmentRecord],
        closed: ClosedUnsubmittedAnswerTimes,
        answered: [Int: ContinuousClock.Instant],
        account: String,
        fetchedAt: Date,
        assignments store: AssignmentStore,
        moodle: MoodleFiles,
        rounds: AssignmentRounds = .shared,
        for signIn: SignIn
    ) -> Bool {
        guard !Task.isCancelled, store.saveAssignments(assignments, for: signIn) else { return false }
        MoodleCacheContext(account: account, cache: moodle, assignments: store, signIn: signIn)
            .save(records, fetchedAt: fetchedAt, name: MoodleAssignmentRecord.cacheName)
        store.replaceClosedUnsubmittedAssignments(closed, for: signIn)
        saveMoodleCalendarEvents(of: assignments, in: store, for: signIn)
        for (id, askedAt) in answered { rounds.statusAskedAt[String(id)] = askedAt }
        return true
    }
}
