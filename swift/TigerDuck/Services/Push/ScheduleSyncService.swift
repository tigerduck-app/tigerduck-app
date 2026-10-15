import Foundation
import os

/// Builds a 48-hour event list from the resolver the on-device Live
/// Activity uses and POSTs it to `/schedule/sync`. 48 hours covers overnight
/// and the next day without letting the server hold a huge pending queue.
/// The app is expected to re-sync on every foreground and every course or
/// assignment cache update.
///
/// `@MainActor` because events read non-`Sendable` SwiftData models; that
/// also guards `inflight`, the only mutable state, so no actor is needed.
@MainActor
final class ScheduleSyncService {
    struct Inputs {
        let courses: [SDCourse]
        let assignments: [SDAssignment]
        let accentHex: Int
        let classPreparingLeadTime: TimeInterval
        let assignmentLeadTime: TimeInterval
        let showClassPreparing: Bool
        let showInClass: Bool
        let showAssignmentScenario: Bool
        /// Whether Live Activity may run on this device at all. On iPhone and
        /// iPad that is `effectiveLiveActivityEnabled` — see the initializer
        /// in the extension below. False makes the upload an empty list: the
        /// backend files a push-to-start job for every event it receives, and
        /// an empty list is what cancels the ones this device queued before.
        let liveActivityAvailable: Bool
        /// The term `courses` belong to. A class goes up only for a day this term is current on
        /// (`CourseSelectionService.semesterCode(on:calendar:)`): the day before a term begins,
        /// the window reaches the new term's first day, whose classes this list does not hold.
        let term: String
        /// The term the window reaches after `term`, with its cached courses: the night before a
        /// term begins, its first day is planned from its own timetable.
        var nextTerm: (code: String, courses: [SDCourse])?
        /// The school calendar and the holidays this user still has class on.
        /// A class event on a day classes do not meet is left out, the rule
        /// the on-device resolver applies, since the server would start an
        /// activity for a class that is not happening. Assignments stay: a
        /// deadline on a day off is still a deadline. The defaults suppress
        /// nothing, like an app that has not fetched the calendar yet.
        var calendar: AcademicCalendar = .empty
        var optedInHolidayIDs: Set<Int> = []
    }

    private let identity: PushIdentity
    private let apiClient: PushAPIClient
    private let horizonSeconds: TimeInterval
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Push.Sync")

    private var inflight: Task<Void, Never>?

    /// How far ahead the uploaded events reach.
    static let horizon: TimeInterval = 48 * 3600

    init(
        identity: PushIdentity,
        apiClient: PushAPIClient,
        horizonHours: Double = ScheduleSyncService.horizon / 3600
    ) {
        self.identity = identity
        self.apiClient = apiClient
        self.horizonSeconds = horizonHours * 3600
    }

    /// Main entry. Failures are logged, never thrown: schedule sync is best
    /// effort and must not block UI or app state.
    ///
    /// `now` defaults to `AppClock.now()` so the server's event window matches
    /// what the Live Activity, widgets and watch show under a debug clock
    /// override. Auth and network timestamps (session TTL, cache age) stay on
    /// real time (see `AppClock`); the schedule horizon is display state.
    func sync(inputs: Inputs, now: Date = AppClock.now()) {
        let end = now.addingTimeInterval(horizonSeconds)
        let events = Self.buildEvents(inputs: inputs, now: now, horizonEnd: end)
        // v3: device identity is inferred from the JWT; no deviceId in the body.
        let request = PushAPI.ScheduleSyncRequest(events: events)
        logger.info("sync start events=\(events.count, privacy: .public)")

        inflight?.cancel()
        inflight = Task { [apiClient, logger] in
            do {
                let response = try await apiClient.syncSchedule(request)
                logger.info(
                    "sync ok pending=\(response.pending, privacy: .public) replaced=\(response.replaced, privacy: .public)"
                )
            } catch {
                logger.error("sync failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    // MARK: - Event construction (pure, testable)

    /// `@MainActor` because it dereferences SwiftData-managed properties
    /// (`course.schedule`, `assignment.dueDate`) whose accessors are
    /// MainActor-isolated under Swift 6 strict concurrency.
    @MainActor
    static func buildEvents(
        inputs: Inputs,
        now: Date,
        horizonEnd: Date,
        timelineResolver: CourseTimelineResolver? = nil
    ) -> [PushAPI.ScheduleEvent] {
        // Without Live Activity there is nothing for the server to start. The
        // empty list still goes out: it cancels the starts this device queued.
        guard inputs.liveActivityAvailable else { return [] }

        var events: [PushAPI.ScheduleEvent] = []

        let resolver = timelineResolver ?? CourseTimelineResolver()
        let terms = [(code: inputs.term, courses: inputs.courses)] + (inputs.nextTerm.map { [$0] } ?? [])
        let futureSlots = terms
            .flatMap { term in
                resolver.timeline(for: term.courses, around: now)
                    .filter { CourseSelectionService.semesterCode(on: $0.date, calendar: inputs.calendar) == term.code }
            }
            .filter { !$0.course.isSkipped(on: $0.date) }
            .filter { inputs.calendar.isClassDay($0.date, optedIn: inputs.optedInHolidayIDs) }
            .filter { $0.start >= now && $0.start <= horizonEnd }

        for slot in futureSlots {
            if inputs.showClassPreparing {
                let fireAt = leadTimeFireAt(
                    desired: slot.start.addingTimeInterval(-inputs.classPreparingLeadTime),
                    event: slot.start,
                    now: now
                )
                if let fireAt {
                    let snapshot = LiveActivityScenarioResolver.classPreparingSnapshot(
                        slot: slot,
                        accentHex: inputs.accentHex
                    )
                    // The server pushes on the real clock, so `fireAt` goes out in
                    // real time; snapshot dates stay app-clock, since the device's
                    // Live Activity handler translates them.
                    events.append(PushAPI.ScheduleEvent(
                        sourceId: snapshot.sourceId,
                        scenario: .classPreparing,
                        fireAt: AppClock.realTime(forApp: fireAt),
                        snapshot: snapshot
                    ))
                }
            }

            if inputs.showInClass {
                let snapshot = LiveActivityScenarioResolver.inClassSnapshot(
                    slot: slot,
                    now: slot.start,
                    accentHex: inputs.accentHex
                )
                events.append(PushAPI.ScheduleEvent(
                    sourceId: snapshot.sourceId,
                    scenario: .inClass,
                    fireAt: AppClock.realTime(forApp: slot.start),
                    snapshot: snapshot
                ))
            }
        }

        if inputs.showAssignmentScenario {
            for assignment in inputs.assignments
                where LiveActivityScenarioResolver.isOutstanding(assignment)
                    && assignment.dueDate > now && assignment.dueDate <= horizonEnd {
                let fireAt = leadTimeFireAt(
                    desired: assignment.dueDate.addingTimeInterval(-inputs.assignmentLeadTime),
                    event: assignment.dueDate,
                    now: now
                )
                guard let fireAt else { continue }
                let snapshot = LiveActivityScenarioResolver.assignmentSnapshot(
                    assignment: assignment,
                    courses: inputs.courses,
                    leadTime: inputs.assignmentLeadTime,
                    accentHex: inputs.accentHex
                )
                events.append(PushAPI.ScheduleEvent(
                    sourceId: snapshot.sourceId,
                    scenario: .assignmentUrgent,
                    fireAt: AppClock.realTime(forApp: fireAt),
                    snapshot: snapshot
                ))
            }
        }

        return events
    }

    /// When a lead-time scenario (classPreparing, assignmentUrgent) fires.
    ///
    /// - `desired` (`event - leadTime`) when it is still in the future.
    /// - Otherwise, if the event is more than 60 s away, `now + 5s`: the user
    ///   still gets the "class starting soon" or "assignment due soon" notice,
    ///   only late. The offset makes the dispatcher see it on its next tick
    ///   instead of skipping it as microseconds past.
    /// - `nil` when the event is past or within 60 s: no useful warning is left.
    private static func leadTimeFireAt(
        desired: Date,
        event: Date,
        now: Date
    ) -> Date? {
        if desired > now {
            return desired
        }
        if event > now.addingTimeInterval(60) {
            return now.addingTimeInterval(5)
        }
        return nil
    }

    /// Wait until any in-flight POST has completed (or terminally errored).
    /// `sync(inputs:)` is fire-and-forget: it returns as soon as the inflight
    /// `Task` is spawned, *not* when the network call finishes. Callers that
    /// must avoid a stale POST resurrecting state they just deleted (e.g.
    /// `PushCoordinator.disable()` before `unregister`) need this barrier.
    func awaitInflight() async {
        await inflight?.value
    }
}

#if os(iOS)
extension ScheduleSyncService.Inputs {
    /// This device's upload, read off the same preferences the on-device
    /// resolver uses, with `liveActivityAvailable` taken from
    /// `effectiveLiveActivityEnabled`: with course sync off, or the user's own
    /// Live Activity switch off, the server has nothing to start. The terms are
    /// read off `now`, the app's clock the window of `sync(inputs:now:)` is on.
    init(
        now: Date,
        courses: (_ term: String) -> [SDCourse],
        assignments: [SDAssignment],
        preferences: LiveActivityPreferencesStore,
        cloudSyncEnabled: Bool,
        accentHex: Int,
        calendar: AcademicCalendar,
        optedInHolidayIDs: Set<Int>
    ) {
        let term = CourseSelectionService.semesterCode(on: now, calendar: calendar)
        self.init(
            courses: courses(term),
            assignments: assignments,
            accentHex: accentHex,
            classPreparingLeadTime: preferences.classPreparingLeadTime,
            assignmentLeadTime: preferences.assignmentLiveActivityLeadTime,
            showClassPreparing: preferences.showClassPreparingScenario,
            showInClass: preferences.showInClassScenario,
            showAssignmentScenario: preferences.showAssignmentScenario,
            liveActivityAvailable: effectiveLiveActivityEnabled(
                isLiveActivityEnabled: preferences.isLiveActivityEnabled,
                cloudSyncEnabled: cloudSyncEnabled
            ),
            term: term,
            calendar: calendar,
            optedInHolidayIDs: optedInHolidayIDs
        )
        let later = CourseSelectionService.semesterCode(on: now.addingTimeInterval(ScheduleSyncService.horizon), calendar: calendar)
        if later != term { nextTerm = (later, courses(later)) }
    }
}
#endif
