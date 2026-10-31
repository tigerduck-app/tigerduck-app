import SwiftUI
import SwiftData
import Defaults
import os

extension AppState {

    func startRevisionPolling(pollNow: Bool = true) {
        guard Defaults[.cloudSyncEnabled] else {
            AppLogger.sync.info("[poll] startRevisionPolling skipped — cloudSyncEnabled=false")
            revisionPoller.stop()
            return
        }
        revisionPoller.start(pollNow: pollNow)
    }

    func stopRevisionPolling() {
        revisionPoller.stop()
    }

    func pollRevision() async -> RevisionPollOutcome {
        guard Defaults[.cloudSyncEnabled] else { return .unchanged }
        guard NetworkMonitor.shared.isConnected else { return .offline }
        await authService.ensureBackendSignedIn()
        guard await authTokenManager.isLoggedIn else { return .unchanged }
        do {
            let serverRevision = try await pushCoordinator.fetchRevision()
            retryOwedConflictCheck()
            AppLogger.sync.info("[poll] server revision=\(serverRevision) lastKnown=\(self._lastKnownRevision)")
            guard serverRevision > _lastKnownRevision else { return .unchanged }
            let outcome = await syncChangesSinceLastRevision()
            await cloudSyncCoordinator.onRevisionChanged()
            return outcome
        } catch PushAPIError.httpStatus(401, _, let sent) {
            return .unauthorized(refused: sent?.value)
        } catch {
            AppLogger.sync.info("[poll] tick failed: \(error, privacy: .private)")
            return .failed
        }
    }

    func syncChangesSinceLastRevision() async -> RevisionPollOutcome {
        let since = _lastKnownRevision
        let ticket = authService.session.ticket
        guard since > 0, !fullSyncGate.isRunning else {
            await syncOverridesFromBackend(followUpIfBusy: true)
            return .changed
        }
        let page: PushAPI.SyncChangesPage?
        do {
            page = try await pushCoordinator.fetchChanges(sinceRevision: since)
        } catch {
            AppLogger.sync.info("[feed] read failed: \(error, privacy: .private)")
            page = nil
        }
        guard mayAdvanceRevision(from: since, ticket: ticket), !fullSyncGate.isRunning else {
            return .changed
        }
        let plan = ChangeFeedPlan(page, since: since)
        AppLogger.sync.info("[feed] since=\(since) plan=\(String(describing: plan), privacy: .public)")
        switch plan {
        case .fullSync:
            await syncOverridesFromBackend()
        case .advance(let revision):
            await retryUnsentEdits()
            advanceRevision(from: since, to: revision, ticket: ticket)
        case .reconcileSettings(let revision):
            await retryUnsentEdits()
            await reconcileSettings(thenAdvanceFrom: since, to: revision, ticket: ticket)
            if _lastKnownRevision == since { return .failed }
        }
        return .changed
    }

    private func reconcileSettings(thenAdvanceFrom since: Int, to revision: Int, ticket: AccountSession.Ticket) async {
        #if os(iOS)
        if !Defaults[.notificationSettingsPushPending] {
            await reconcileNotificationSettings(onSettled: { [weak self] in
                self?.advanceRevision(from: since, to: revision, ticket: ticket)
            }).value
            return
        }
        #endif
        advanceRevision(from: since, to: revision, ticket: ticket)
    }

    private func advanceRevision(from since: Int, to revision: Int, ticket: AccountSession.Ticket) {
        guard mayAdvanceRevision(from: since, ticket: ticket) else { return }
        _lastKnownRevision = revision
        ServerStatusTracker.shared.noteSyncResult(true)
    }

    private func mayAdvanceRevision(from since: Int, ticket: AccountSession.Ticket) -> Bool {
        Self.feedMayAdvanceRevision(
            readAfter: since,
            watermark: _lastKnownRevision,
            signedOutSince: !authService.session.isCurrent(ticket),
            cloudSyncEnabled: Defaults[.cloudSyncEnabled]
        )
    }

    nonisolated static func feedMayAdvanceRevision(
        readAfter since: Int,
        watermark: Int,
        signedOutSince: Bool,
        cloudSyncEnabled: Bool
    ) -> Bool {
        since == watermark
            && fullSyncMayWrite(
                signedOutSince: signedOutSince, cloudSyncEnabled: cloudSyncEnabled, protectedDataAvailable: true
            )
    }

    func backgroundSync(recheckSubmissions: Bool = false) {
        guard hasCompletedOnboarding else { return }
        startRevisionPolling(pollNow: false)
        // The first scene of a launch, and the end of onboarding, bring no scene-active refresh.
        Task { await CourseChangeStore.shared.refresh() }
        syncTask?.cancel()
        syncTask = Task {
            // Behind a hotel or campus Wi-Fi login page the link is "satisfied" but
            // egress is blocked, and the pinned NTUST hosts would hard-fail with an ATS
            // error. Bail early with a clean "no internet" message instead.
            guard await NetworkMonitor.shared.isReachable() else {
                await MainActor.run {
                    sessionManager.loadingState = .error(String(localized: "error_network_unavailable"))
                }
                return
            }

            sessionManager.loadingState = .loading

            if recheckSubmissions { MoodleEnrolledCoursesService.dropSharedAnswer() }
            _ = await AppServiceBridge.fetchAssignments(
                authService: authService, recheckSubmissions: recheckSubmissions
            )
            await syncOverridesFromBackend(followUpIfBusy: true)

            async let schoolEventsTask = CalendarService.fetchAndParseICS()
            async let coursesTask: Bool = syncCoursesIfAuthenticated()

            let fetchedSchoolEvents = await schoolEventsTask
            _ = await coursesTask

            guard !Task.isCancelled else { return }

            if let fetchedSchoolEvents {
                var calendarCache = DataCache.shared.loadCalendarEvents()
                calendarCache.removeAll { $0.source == .school }
                calendarCache.append(contentsOf: fetchedSchoolEvents)
                DataCache.shared.saveCalendarEvents(calendarCache)
            }

            await MainActor.run {
                guard !Task.isCancelled else { return }
                sessionManager.loadingState = .loaded
                NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
            }
        }
    }

    private func syncCoursesIfAuthenticated() async -> Bool {
        guard let studentId = authService.storedStudentId else { return false }
        let semester = CourseSelectionService.currentSemesterCode()
        if CourseSelectionService.needsSchoolSession(studentId: studentId, semester: semester) {
            guard await authService.ensureAuthenticated() else { return false }
        } else {
            await authService.ensureBackendSignedIn()
        }
        _ = await AppServiceBridge.fetchCourses(authService: authService, semester: semester)
        return true
    }
}

nonisolated enum RevisionPollOutcome: Equatable, Sendable {
    case unchanged
    case changed
    case failed
    /// `refused` is the access token the refused request sent.
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
    var relogin: @MainActor (_ refused: String?) async -> Bool = { _ in false }

    private let sleep: @Sendable (Duration) async -> Void
    private let now: () -> Date
    private let jitter: () -> Double
    private var schedule: RevisionPollSchedule
    private var isRunning = false
    private(set) var isPolling = false
    private(set) var isSuspended = false
    private var reloginTried = false
    private var wait: Task<Void, Never>?
    private var nextPollAt: Date?
    private var lastPollAt: Date?

    init(
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        now: @escaping () -> Date = { Date() },
        jitter: @escaping () -> Double = { Double.random(in: 0...1) }
    ) {
        self.sleep = sleep
        self.now = now
        self.jitter = jitter
        schedule = RevisionPollSchedule(now: now())
    }

    func start(pollNow: Bool) {
        isRunning = true
        isSuspended = false
        reloginTried = false
        schedule.noteActivity(at: now())
        guard !isPolling else { return }
        let sinceLastPoll = lastPollAt.map { now().timeIntervalSince($0) } ?? .infinity
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

    func noteActivity() {
        schedule.noteActivity(at: now())
        guard isRunning, !isSuspended, !isPolling else { return }
        let soonest = now().addingTimeInterval(RevisionPollSchedule.activeInterval)
        if let nextPollAt, nextPollAt <= soonest { return }
        arm(after: RevisionPollSchedule.activeInterval)
    }

    private func pollOnce() {
        guard isRunning, !isSuspended, !isPolling else { return }
        isPolling = true
        lastPollAt = now()
        Task { [weak self] in
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
            schedule.noteActivity(at: now())
            delay = schedule.delayAfterAnswer(at: now())
        case .unchanged:
            delay = schedule.delayAfterAnswer(at: now())
        case .offline:
            delay = schedule.currentInterval(at: now())
        case .failed:
            delay = schedule.delayAfterFailure(at: now(), jitter: jitter())
        case .unauthorized(let refused):
            guard !reloginTried else {
                isSuspended = true
                return
            }
            reloginTried = true
            guard await relogin(refused) else {
                isSuspended = true
                return
            }
            delay = 0
        }
        guard isRunning, !isSuspended else { return }
        arm(after: delay)
    }

    private func arm(after delay: TimeInterval) {
        cancelWait()
        nextPollAt = now().addingTimeInterval(delay)
        wait = Task { [weak self, sleep] in
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
