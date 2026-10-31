import ActivityKit
import Foundation

/// Which running activities `LiveActivityCoordinator` ends and which snapshot it may start: the
/// reasons swift/TigerDuck/Devices/LiveActivity/AGENTS.md lists, read from plain facts.
nonisolated enum LiveActivityEndRules {
    nonisolated struct RunningActivityFacts: Equatable, Sendable {
        let instanceId: String
        let activityId: String
        let sourceId: String
        let scenario: LiveActivityScenarioKind
        let countdownTarget: Date?
        let hasPushToken: Bool
        let isLive: Bool
    }

    nonisolated enum EndReason: String, Sendable {
        case unavailable = "Live Activity unavailable"
        case expired = "countdown expired"
        case quietDay = "classes do not meet that day"
        case skippedClass = "class skipped that day"
        case assignmentDone = "assignment submitted, ignored or marked done"
    }

    /// The app's answers the rules ask for, set once by the app.
    @MainActor
    struct Conditions {
        var isAvailable: () -> Bool = { true }
        var isQuietDay: (Date) -> Bool = { _ in false }
        var isAssignmentOutstanding: (String) -> Bool? = { _ in nil }
        var isSkipped: (String) -> Bool = { _ in false }

        func endReason(for activity: Activity<TigerDuckActivityAttributes>, now: Date, isAvailable: Bool) -> EndReason? {
            LiveActivityEndRules.endReason(
                for: LiveActivityEndRules.facts(of: activity),
                now: now,
                isAvailable: isAvailable,
                isQuietDay: isQuietDay,
                isAssignmentOutstanding: isAssignmentOutstanding,
                isSkipped: isSkipped
            )
        }

        func canStart(_ snapshot: LiveActivitySnapshot) -> Bool {
            LiveActivityEndRules.canStart(
                snapshot,
                isAvailable: isAvailable(),
                isQuietDay: isQuietDay,
                isAssignmentOutstanding: isAssignmentOutstanding,
                isSkipped: isSkipped
            )
        }
    }

    static func facts(of activity: Activity<TigerDuckActivityAttributes>) -> RunningActivityFacts {
        RunningActivityFacts(
            instanceId: activity.id,
            activityId: activity.attributes.activityId,
            sourceId: activity.content.state.snapshot.sourceId,
            scenario: activity.content.state.snapshot.scenario,
            countdownTarget: activity.content.state.snapshot.countdownTarget,
            hasPushToken: activity.pushToken != nil,
            isLive: activity.activityState == .active
                || activity.activityState == .stale
        )
    }

    static func expiredInstanceIds(
        _ facts: [RunningActivityFacts],
        now: Date
    ) -> [String] {
        facts
            .filter { $0.countdownTarget.map { $0 <= now } ?? false }
            .map(\.instanceId)
    }

    static func instanceIdsToEnd(
        _ facts: [RunningActivityFacts],
        now: Date,
        isAvailable: Bool,
        isQuietDay: (Date) -> Bool = { _ in false },
        isAssignmentOutstanding: (String) -> Bool? = { _ in nil },
        isSkipped: (String) -> Bool = { _ in false }
    ) -> [String] {
        facts
            .filter {
                endReason(
                    for: $0,
                    now: now,
                    isAvailable: isAvailable,
                    isQuietDay: isQuietDay,
                    isAssignmentOutstanding: isAssignmentOutstanding,
                    isSkipped: isSkipped
                ) != nil
            }
            .map(\.instanceId)
    }

    static func endReason(
        for fact: RunningActivityFacts,
        now: Date,
        isAvailable: Bool,
        isQuietDay: (Date) -> Bool,
        isAssignmentOutstanding: (String) -> Bool?,
        isSkipped: (String) -> Bool
    ) -> EndReason? {
        if !isAvailable { return .unavailable }
        if !expiredInstanceIds([fact], now: now).isEmpty { return .expired }
        if !quietClassInstanceIds([fact], isQuietDay: isQuietDay).isEmpty { return .quietDay }
        if isSkippedClass(fact.scenario, sourceId: fact.sourceId, isSkipped: isSkipped) { return .skippedClass }
        if isDoneAssignment(
            fact.scenario,
            sourceId: fact.sourceId,
            isAssignmentOutstanding: isAssignmentOutstanding
        ) {
            return .assignmentDone
        }
        return nil
    }

    static func quietClassInstanceIds(
        _ facts: [RunningActivityFacts],
        isQuietDay: (Date) -> Bool
    ) -> [String] {
        facts
            .filter {
                isQuietClass($0.scenario, countdownTarget: $0.countdownTarget, isQuietDay: isQuietDay)
            }
            .map(\.instanceId)
    }

    static func isQuietClass(
        _ scenario: LiveActivityScenarioKind,
        countdownTarget: Date?,
        isQuietDay: (Date) -> Bool
    ) -> Bool {
        [.classPreparing, .inClass].contains(scenario)
            && (countdownTarget.map(isQuietDay) ?? false)
    }

    static func isSkippedClass(
        _ scenario: LiveActivityScenarioKind,
        sourceId: String,
        isSkipped: (String) -> Bool
    ) -> Bool {
        [.classPreparing, .inClass].contains(scenario) && isSkipped(sourceId)
    }

    static func isDoneAssignment(
        _ scenario: LiveActivityScenarioKind,
        sourceId: String,
        isAssignmentOutstanding: (String) -> Bool?
    ) -> Bool {
        scenario == .assignmentUrgent && isAssignmentOutstanding(sourceId) == false
    }

    static func canStart(
        _ snapshot: LiveActivitySnapshot,
        isAvailable: Bool,
        isQuietDay: (Date) -> Bool,
        isAssignmentOutstanding: (String) -> Bool?,
        isSkipped: (String) -> Bool
    ) -> Bool {
        isAvailable
            && !isQuietClass(
                snapshot.scenario,
                countdownTarget: snapshot.countdownTarget,
                isQuietDay: isQuietDay
            )
            && !isSkippedClass(snapshot.scenario, sourceId: snapshot.sourceId, isSkipped: isSkipped)
            && !isDoneAssignment(
                snapshot.scenario,
                sourceId: snapshot.sourceId,
                isAssignmentOutstanding: isAssignmentOutstanding
            )
    }

    static func duplicateInstanceIdsToEnd(
        _ facts: [RunningActivityFacts]
    ) -> [String] {
        var result: [String] = []
        let live = facts.filter(\.isLive)
        for (_, copies) in Dictionary(grouping: live, by: \.activityId)
        where copies.count > 1 {
            guard let keeper = copies.first(where: \.hasPushToken)
                ?? copies.min(by: { $0.instanceId < $1.instanceId })
            else { continue }
            result.append(
                contentsOf: copies
                    .filter { $0.instanceId != keeper.instanceId }
                    .map(\.instanceId)
            )
        }
        return result.sorted()
    }
}
