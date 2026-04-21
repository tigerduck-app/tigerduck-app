import Defaults
import Foundation
import os

/// Builds a 48-hour event list from the same resolver the on-device Live
/// Activity uses, and POSTs it to `/v1/schedule/sync`.
///
/// Why 48 hours: enough headroom to cover overnight + next day without
/// letting the server hold a huge pending queue. The app is expected to
/// re-sync whenever it foregrounds (`scenePhase == .active`) and whenever
/// the course / assignment cache updates.
///
/// Concurrency: event construction runs on `@MainActor` because it reads
/// SwiftData-backed models (`SDCourse`, `SDAssignment`) which are not
/// `Sendable`. The network call itself is `async` and safely handed off
/// to `URLSession`. We don't need an actor wrapper — the service holds
/// no mutable state beyond an inflight task handle, protected by
/// `@MainActor` isolation.
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
    }

    private let identity: PushIdentity
    private let apiClient: PushAPIClient
    private let horizonSeconds: TimeInterval
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Push.Sync")

    private var inflight: Task<Void, Never>?

    init(
        identity: PushIdentity,
        apiClient: PushAPIClient,
        horizonHours: Double = 48
    ) {
        self.identity = identity
        self.apiClient = apiClient
        self.horizonSeconds = horizonHours * 3600
    }

    /// Main entry. Failures are logged but never thrown — schedule sync is
    /// best-effort and must not block UI or app state.
    func sync(inputs: Inputs, now: Date = Date()) {
        let end = now.addingTimeInterval(horizonSeconds)
        let events = Self.buildEvents(inputs: inputs, now: now, horizonEnd: end)
        let request = PushAPI.ScheduleSyncRequest(
            deviceId: identity.deviceId,
            events: events
        )
        logger.info("sync start events=\(events.count, privacy: .public)")

        inflight?.cancel()
        inflight = Task { [apiClient, logger, weak self] in
            do {
                let response = try await apiClient.syncSchedule(request)
                logger.info(
                    "sync ok scheduled=\(response.scheduled, privacy: .public) cancelled=\(response.cancelled, privacy: .public) pending=\(response.totalPending, privacy: .public)"
                )
                self?.markSuccess()
            } catch {
                logger.error("sync failed: \(error.localizedDescription, privacy: .public)")
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
        var events: [PushAPI.ScheduleEvent] = []

        let resolver = timelineResolver ?? CourseTimelineResolver()
        let timeline = resolver.timeline(for: inputs.courses, around: now)
        let futureSlots = timeline
            .filter { !$0.course.isSkipped(on: $0.date) }
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
                        fireAt: fireAt,
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
                    fireAt: slot.start,
                    snapshot: snapshot
                ))
            }
        }

        if inputs.showAssignmentScenario {
            for assignment in inputs.assignments
                where !assignment.isCompleted && assignment.dueDate > now && assignment.dueDate <= horizonEnd {
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
                    fireAt: fireAt,
                    snapshot: snapshot
                ))
            }
        }

        return events
    }

    /// Decide when a lead-time-driven scenario (classPreparing / assignmentUrgent)
    /// should actually fire.
    ///
    /// - `desired` is `event - leadTime`. When it's in the future we use it.
    /// - When it's already past but the underlying event is still in the
    ///   future, we fire immediately (`now + 5s` — small offset so dispatcher
    ///   sees it on its very next tick rather than skipping for being
    ///   microseconds in the past). User still gets the "即將上課 / 作業將到期"
    ///   heads-up, just later than the user's ideal lead time.
    /// - When the event itself is past or within 60s, we skip — there's no
    ///   useful warning left to deliver.
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

    private func markSuccess() {
        Defaults[.pushLastSyncAt] = Date()
    }
}
