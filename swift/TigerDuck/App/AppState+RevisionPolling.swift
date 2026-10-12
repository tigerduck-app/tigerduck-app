// The backend's monotonic revision counter answers "did anything change?" without
// pulling the whole override set; `RevisionPoller` asks it in the foreground. `backgroundSync`
// is the launch and sign-in sync that fans out to the independent fetches.

import SwiftUI
import SwiftData
import Defaults
import os

extension AppState {

    // MARK: - Revision polling

    /// Starts the foreground revision poll, or restarts it on a return to the app.
    /// `pollNow` asks at once; launch and sign-in pass false, since their sync pulls anyway.
    func startRevisionPolling(pollNow: Bool = true) {
        guard Defaults[.cloudSyncEnabled] else {
            AppLogger.sync.info("[poll] startRevisionPolling skipped — cloudSyncEnabled=false")
            revisionPoller.stop()
            return
        }
        revisionPoller.start(pollNow: pollNow)
    }

    /// Stop the foreground revision poller (e.g. when the app backgrounds).
    func stopRevisionPolling() {
        revisionPoller.stop()
    }

    /// One poll: fetch the lightweight revision endpoint, compare with
    /// ``_lastKnownRevision``, and run a full sync when the server is ahead.
    func pollRevision() async -> RevisionPollOutcome {
        guard Defaults[.cloudSyncEnabled], await authTokenManager.isLoggedIn else { return .unchanged }
        guard NetworkMonitor.shared.isConnected else { return .offline }
        do {
            let serverRevision = try await pushCoordinator.fetchRevision()
            AppLogger.sync.info("[poll] server revision=\(serverRevision) lastKnown=\(self._lastKnownRevision)")
            guard serverRevision > _lastKnownRevision else { return .unchanged }
            await syncOverridesFromBackend()
            await cloudSyncCoordinator.onRevisionChanged()
            return .changed
        } catch PushAPIError.httpStatus(401, _) {
            return .unauthorized
        } catch {
            AppLogger.sync.info("[poll] tick failed: \(error, privacy: .public)")
            return .failed
        }
    }

    /// Background sync all data on app launch.
    ///
    /// Three independent tracks run in parallel. Moodle rides a long-
    /// lived OIDC token (no NTUST SSO dependency), the ICS calendar is
    /// public, and the courses track owns its own auth check so Moodle
    /// and ICS are never held up behind `ensureAuthenticated()`.
    ///
    /// `recheckSubmissions` is for Refresh on the Mac, which has no pull.
    func backgroundSync(recheckSubmissions: Bool = false) {
        guard hasCompletedOnboarding else { return }
        startRevisionPolling(pollNow: false)
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

            // Moodle-direct for the assignment list (proven, correct
            // semester filtering). Backend handles override sync only.
            if recheckSubmissions { MoodleEnrolledCoursesService.dropSharedAnswer() }
            _ = await AppServiceBridge.fetchAssignments(
                authService: authService, recheckSubmissions: recheckSubmissions
            )
            await syncOverridesFromBackend()

            async let schoolEventsTask = CalendarService.fetchAndParseICS()
            async let coursesTask: Bool = syncCoursesIfAuthenticated()

            let fetchedSchoolEvents = await schoolEventsTask
            _ = await coursesTask

            // Bail out before persisting if logout cancelled this sync mid-flight. The
            // merged calendar would otherwise land on the freshly purged cache and
            // resurface the previous user's events.
            guard !Task.isCancelled else { return }

            // Moodle rows stay as they are: every assignment round writes them, and a pull's
            // round may have written newer ones than this sync's while it fetched courses.
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

    /// Runs the course list refresh of background sync. Factored out so `backgroundSync` can
    /// launch it via `async let` alongside the independent Moodle and ICS fetches. It signs in
    /// to SSO only when the course-selection list is due; the rest needs no school session.
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

/// What one revision poll found.
nonisolated enum RevisionPollOutcome: Equatable, Sendable {
    case unchanged
    case changed
    case failed
    case unauthorized
    /// No network to ask on, so no request was made.
    case offline
}

/// When the foreground revision poll asks next. A sync trigger push covers only marks, course
/// overrides and the server's Moodle sync, and a Mac gets none, so the idle cap stays short.
/// See https://github.com/tigerduck-app/tigerduck-app/issues/238.
nonisolated struct RevisionPollSchedule: Sendable {
    /// The cadence for `activeWindow` after a return to the app, a change or a local edit.
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

    /// The wait after an answer: the active cadence, or twice the last idle wait up to the cap.
    mutating func delayAfterAnswer(at now: Date) -> TimeInterval {
        failures = 0
        guard now >= activeUntil else { return Self.activeInterval }
        idleInterval = min(Self.idleCap, idleInterval * 2)
        return idleInterval
    }

    /// The wait after a failure: the current wait doubled per failure in a row, up to the cap,
    /// with `jitter` in 0...1 spreading it over its upper half so devices do not retry in step.
    mutating func delayAfterFailure(at now: Date, jitter: Double) -> TimeInterval {
        failures += 1
        let backoff = min(Self.failureCap, currentInterval(at: now) * pow(2, Double(failures)))
        return backoff * (0.5 + 0.5 * min(max(jitter, 0), 1))
    }

    /// The wait the schedule is at, without moving it.
    func currentInterval(at now: Date) -> TimeInterval {
        now < activeUntil ? Self.activeInterval : idleInterval
    }
}

/// Runs the foreground revision poll on ``RevisionPollSchedule``, one request at a time. A 401
/// gets one relogin; another 401, or a failed relogin, stops polling until the next ``start``.
@MainActor
final class RevisionPoller {
    /// One poll. `AppState` sets it to `pollRevision()`.
    var poll: @MainActor () async -> RevisionPollOutcome = { .unchanged }
    /// One relogin after a 401. `AppState` sets it to `attemptBackendRelogin()`.
    var relogin: @MainActor () async -> Bool = { false }

    private let sleep: @Sendable (Duration) async -> Void
    private let now: () -> Date
    private let jitter: () -> Double
    private var schedule: RevisionPollSchedule
    private var isRunning = false
    /// Set from a poll's start until its next wait is armed, relogin included.
    private(set) var isPolling = false
    /// Set by a 401 that the relogin did not cure; cleared by ``start``.
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

    /// Starts polling, or restarts it as on a return to the app. `pollNow` still waits out the
    /// active cadence since the last poll, so quick scene toggles do not add requests. A poll
    /// already in flight is not doubled: it arms the next wait when it lands.
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

    /// Stops arming polls. A request in flight finishes, so a full sync it started is not cut off.
    func stop() {
        isRunning = false
        cancelWait()
    }

    /// A local edit: back to the active cadence, sooner than a longer wait already armed.
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
        // Its own task, so a stop or a restart never cancels a request or the sync it runs.
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
        case .unauthorized:
            guard !reloginTried else {
                isSuspended = true
                return
            }
            reloginTried = true
            guard await relogin() else {
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
