import Foundation
import os
#if canImport(UIKit)
import UIKit
#endif

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
        let liveActivityAvailable: Bool
        let term: String
        var nextTerm: (code: String, courses: [SDCourse])?
        var calendar: AcademicCalendar = .empty
        var optedInHolidayIDs: Set<Int> = []
    }

    private let identity: PushIdentity
    private let apiClient: PushAPIClient
    private let signIns: SignInSeries
    private let ledger: SendLedger
    private let horizonSeconds: TimeInterval
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Push.Sync")

    private var inflight: Task<Void, Never>?
    private var pendingRequest: Task<Void, Never>?

    static let horizon: TimeInterval = 48 * 3600

    init(
        identity: PushIdentity,
        apiClient: PushAPIClient,
        signIns: SignInSeries,
        ledger: SendLedger? = nil,
        horizonHours: Double = ScheduleSyncService.horizon / 3600
    ) {
        self.identity = identity
        self.apiClient = apiClient
        self.signIns = signIns
        self.ledger = ledger ?? SendLedger()
        self.horizonSeconds = horizonHours * 3600
    }

    /// Builds the list now and sends it for the sign-in it was built in.
    func sync(building build: @MainActor () -> Inputs) {
        let signIn = signIns.currentSignIn
        sync(inputs: build(), for: signIn)
    }

    func sync(inputs: Inputs, for signIn: SignIn, now: Date = AppClock.now()) {
        let end = now.addingTimeInterval(horizonSeconds)
        let events = Self.buildEvents(inputs: inputs, now: now, horizonEnd: end)
        let request = PushAPI.ScheduleSyncRequest(events: events)
        let fingerprint = SendLedger.fingerprint(of: request)
        let previous = inflight
        inflight = Task { [apiClient, ledger, logger] in
            await previous?.value
            do {
                let sent = try await ledger.send(
                    SendLedger.Channel.schedule, fingerprint: fingerprint, resend: .never
                ) {
                    let response = try await apiClient.syncSchedule(request, for: signIn)
                    logger.info(
                        "sync ok pending=\(response.pending, privacy: .public) replaced=\(response.replaced, privacy: .public)"
                    )
                }
                if !sent { logger.info("sync skipped, list unchanged") }
            } catch {
                logger.error("sync failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    @MainActor
    static func buildEvents(
        inputs: Inputs,
        now: Date,
        horizonEnd: Date,
        timelineResolver: CourseTimelineResolver? = nil
    ) -> [PushAPI.ScheduleEvent] {
        guard inputs.liveActivityAvailable else { return [] }

        var events: [PushAPI.ScheduleEvent] = []

        let resolver = timelineResolver ?? CourseTimelineResolver()
        let terms = [(code: inputs.term, courses: inputs.courses)] + (inputs.nextTerm.map { [$0] } ?? [])
        let futureSlots = terms
            .flatMap { term in
                resolver.timeline(for: term.courses, around: now)
                    .filter { CourseSelectionService.semesterCode(on: $0.date, calendar: inputs.calendar) == term.code }
            }
            .filter { !$0.isSkippedOrCancelled }
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

    func awaitInflight() async {
        await inflight?.value
    }

    /// Sends the list `debounce` after the last request, unless the app is in the background or
    /// signed out by then.
    func request(after debounce: Duration, inputsBuilder: @escaping @MainActor () -> Inputs) {
        pendingRequest?.cancel()
        pendingRequest = Task { @MainActor [weak self] in
            try? await AppClock.sleep(until: ContinuousClock.now + debounce)
            guard !Task.isCancelled else { return }
            #if os(iOS)
            guard UIApplication.shared.applicationState != .background else { return }
            #endif
            guard await self?.apiClient.hasAuthSession() == true else { return }
            self?.sync(building: inputsBuilder)
        }
    }

    func cancelRequest() async {
        pendingRequest?.cancel()
        await pendingRequest?.value
    }

    func forgetAcceptedList() {
        ledger.forget(SendLedger.Channel.schedule)
    }
}

#if os(iOS)
extension ScheduleSyncService.Inputs {
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
