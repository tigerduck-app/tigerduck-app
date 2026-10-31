import Foundation

nonisolated enum RevisionPollOutcome: Equatable, Sendable {
    case unchanged
    case changed
    case failed
    /// `refused` is the access token the refused request sent, which the client could not replace.
    case unauthorized(refused: String?)
    case offline
}

nonisolated enum ChangeFeedPlan: Equatable, Sendable {
    case fullSync
    case advance(to: Int)
    case reconcileSettings(thenAdvanceTo: Int)

    static let passedOver: Set<String> = [
        "assignment", "bulletin_subscription", "bulletin_state", "bulletin_match",
    ]

    init(_ page: PushAPI.SyncChangesPage?, since: Int) {
        guard let page, !page.hasMore,
              page.returnedUntilRevision == page.currentRevision,
              page.changes.last?.revision == page.currentRevision,
              page.changes.allSatisfy({ $0.revision > since })
        else {
            self = .fullSync
            return
        }
        let applied = Set(page.changes.map(\.entityType)).subtracting(Self.passedOver)
        if applied.isEmpty {
            self = .advance(to: page.returnedUntilRevision)
        } else if applied == ["settings_document"] {
            self = .reconcileSettings(thenAdvanceTo: page.returnedUntilRevision)
        } else {
            self = .fullSync
        }
    }
}

nonisolated struct RevisionPollSchedule: Sendable {
    static let activeInterval: TimeInterval = 10
    static let activeWindow: TimeInterval = 60
    #if os(macOS)
    static let idleCap: TimeInterval = 120
    #else
    static let idleCap: TimeInterval = 60
    #endif
    static let failureCap: TimeInterval = 300

    private var activeUntil: Date
    private var idleInterval = Self.activeInterval
    private var failures = 0

    init(now: Date) {
        activeUntil = now.addingTimeInterval(Self.activeWindow)
    }

    mutating func noteActivity(at now: Date) {
        activeUntil = now.addingTimeInterval(Self.activeWindow)
        idleInterval = Self.activeInterval
    }

    mutating func delayAfterAnswer(at now: Date) -> TimeInterval {
        failures = 0
        guard now >= activeUntil else { return Self.activeInterval }
        idleInterval = min(Self.idleCap, idleInterval * 2)
        return idleInterval
    }

    mutating func delayAfterFailure(at now: Date, jitter: Double) -> TimeInterval {
        failures += 1
        let backoff = min(Self.failureCap, currentInterval(at: now) * pow(2, Double(failures)))
        return backoff * (0.5 + 0.5 * min(max(jitter, 0), 1))
    }

    func currentInterval(at now: Date) -> TimeInterval {
        now < activeUntil ? Self.activeInterval : idleInterval
    }
}

@MainActor
final class RevisionPoller {
    var poll: @MainActor () async -> RevisionPollOutcome = { .unchanged }

    private let clock: Clock

    /// The waits, the time and the spread of retries, which tests set.
    private struct Clock {
        let sleep: @Sendable (Duration) async -> Void
        let now: () -> Date
        let jitter: () -> Double
    }
    private var schedule: RevisionPollSchedule
    private var isRunning = false
    private(set) var isPolling = false
    private(set) var isSuspended = false
    private var wait: Task<Void, Never>?
    private var inFlight: Task<Void, Never>?
    private var nextPollAt: Date?
    private var lastPollAt: Date?

    init(
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        now: @escaping () -> Date = { Date() },
        jitter: @escaping () -> Double = { Double.random(in: 0...1) }
    ) {
        clock = Clock(sleep: sleep, now: now, jitter: jitter)
        schedule = RevisionPollSchedule(now: now())
    }

    func start(pollNow: Bool) {
        isRunning = true
        isSuspended = false
        schedule.noteActivity(at: clock.now())
        guard !isPolling else { return }
        let sinceLastPoll = lastPollAt.map { clock.now().timeIntervalSince($0) } ?? .infinity
        let delay = pollNow
            ? max(0, RevisionPollSchedule.activeInterval - max(0, sinceLastPoll))
            : RevisionPollSchedule.activeInterval
        if delay == 0 {
            cancelWait()
            pollOnce()
        } else {
            arm(after: delay)
        }
    }

    func stop() {
        isRunning = false
        cancelWait()
    }

    /// Returns once the poll in flight, if one is, has answered.
    func pollInFlight() async {
        await inFlight?.value
    }

    func noteActivity() {
        schedule.noteActivity(at: clock.now())
        guard isRunning, !isSuspended, !isPolling else { return }
        let soonest = clock.now().addingTimeInterval(RevisionPollSchedule.activeInterval)
        if let nextPollAt, nextPollAt <= soonest { return }
        arm(after: RevisionPollSchedule.activeInterval)
    }

    private func pollOnce() {
        guard isRunning, !isSuspended, !isPolling else { return }
        isPolling = true
        lastPollAt = clock.now()
        inFlight = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.poll()
            await self.finish(outcome)
        }
    }

    private func finish(_ outcome: RevisionPollOutcome) async {
        defer { isPolling = false }
        let delay: TimeInterval
        switch outcome {
        case .changed:
            schedule.noteActivity(at: clock.now())
            delay = schedule.delayAfterAnswer(at: clock.now())
        case .unchanged:
            delay = schedule.delayAfterAnswer(at: clock.now())
        case .offline:
            delay = schedule.currentInterval(at: clock.now())
        case .failed:
            delay = schedule.delayAfterFailure(at: clock.now(), jitter: clock.jitter())
        case .unauthorized:
            // `BackendClient` already refreshed or signed in again once; polling waits for a return.
            isSuspended = true
            return
        }
        guard isRunning, !isSuspended else { return }
        arm(after: delay)
    }

    private func arm(after delay: TimeInterval) {
        cancelWait()
        nextPollAt = clock.now().addingTimeInterval(delay)
        wait = Task { [weak self, sleep = clock.sleep] in
            await sleep(.seconds(delay))
            guard !Task.isCancelled else { return }
            self?.nextPollAt = nil
            self?.pollOnce()
        }
    }

    private func cancelWait() {
        wait?.cancel()
        wait = nil
        nextPollAt = nil
    }
}
