import ActivityKit
import Foundation
import os

nonisolated struct LiveActivityUpdateTokenRegistration: Sendable {
    let activityId: String
    let updateTokenHex: String
    let snapshot: LiveActivitySnapshot
    let countdownTargetRealTime: Date?

    init(activityId: String, updateTokenHex: String, snapshot: LiveActivitySnapshot) {
        self.activityId = activityId
        self.updateTokenHex = updateTokenHex
        self.snapshot = snapshot
        countdownTargetRealTime = snapshot.countdownTarget.map(AppClock.realTime(forApp:))
    }
}

@MainActor
final class LiveActivityCoordinator {
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "LiveActivity")
    private var automaticEndTasks: [String: Task<Void, Never>] = [:]
    private var activityObserverTask: Task<Void, Never>?
    private var activityUpdateTokenTasks: [String: Task<Void, Never>] = [:]
    private var endedActivityIds: Set<String> = []
    private var updateTokenRegistrationHandler: (@Sendable (LiveActivityUpdateTokenRegistration) async -> Void)?
    private var isAvailable: () -> Bool = { true }
    private var isQuietDay: (Date) -> Bool = { _ in false }
    private var isAssignmentOutstanding: (String) -> Bool? = { _ in nil }
    private var isSkipped: (String) -> Bool = { _ in false }

    init() {
        startActivityObserver()
    }

    deinit {
        activityObserverTask?.cancel()
        for task in automaticEndTasks.values {
            task.cancel()
        }
        for task in activityUpdateTokenTasks.values {
            task.cancel()
        }
    }

    func setUpdateTokenRegistrationHandler(
        _ handler: @escaping @Sendable (LiveActivityUpdateTokenRegistration) async -> Void
    ) {
        updateTokenRegistrationHandler = handler
    }

    func setAvailabilityProvider(_ provider: @escaping () -> Bool) {
        isAvailable = provider
    }

    func setQuietDayProvider(_ provider: @escaping (Date) -> Bool) {
        isQuietDay = provider
    }

    func setAssignmentOutstandingProvider(_ provider: @escaping (String) -> Bool?) {
        isAssignmentOutstanding = provider
    }

    func setSkippedClassProvider(_ provider: @escaping (String) -> Bool) {
        isSkipped = provider
    }

    func apply(snapshot: LiveActivitySnapshot?) async {
        let now = AppClock.now()
        await pruneRunningActivities(now: now)

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            logger.info("Live Activities are disabled by the system")
            return
        }

        guard let snapshot,
              Self.canStart(
                  snapshot,
                  isAvailable: isAvailable(),
                  isQuietDay: isQuietDay,
                  isAssignmentOutstanding: isAssignmentOutstanding,
                  isSkipped: isSkipped
              )
        else {
            return
        }

        let targetId = snapshot.composedActivityId
        let runningActivities = Activity<TigerDuckActivityAttributes>.activities

        let state = TigerDuckActivityAttributes.ContentState(snapshot: snapshot)
        let realStaleDate = snapshot.countdownTarget.map(AppClock.realTime(forApp:))
        let content = ActivityContent(state: state, staleDate: realStaleDate)

        if let matching = runningActivities.first(where: {
            $0.attributes.activityId == targetId && !endedActivityIds.contains($0.id)
        }) {
            if matching.content.state.snapshot != snapshot {
                await matching.update(content)
            }
            observeUpdateToken(for: matching)
            scheduleAutomaticEnd(for: targetId, snapshot: snapshot, now: now)
        } else {
            do {
                let activity = try Activity<TigerDuckActivityAttributes>.request(
                    attributes: TigerDuckActivityAttributes(activityId: targetId),
                    content: content,
                    pushType: updateTokenRegistrationHandler == nil ? nil : .token
                )
                observeUpdateToken(for: activity)
                scheduleAutomaticEnd(for: targetId, snapshot: snapshot, now: now)
            } catch {
                logger.error("Failed to start Live Activity: \(error.localizedDescription, privacy: .private)")
                AppLogger.captureError(error, context: [
                    "phase": "liveActivity.requestStart",
                    "activityId": targetId,
                ])
            }
        }
    }

    func endAll() async {
        for activity in Activity<TigerDuckActivityAttributes>.activities {
            await end(activity, reason: "endAll")
        }
        cancelAutomaticEndTasks()
        cancelUpdateTokenTasks()
    }

    private func startActivityObserver() {
        activityObserverTask = Task { @MainActor [weak self] in
            for await activity in Activity<TigerDuckActivityAttributes>.activityUpdates {
                guard let self else { return }
                let now = AppClock.now()
                await pruneRunningActivities(now: now)
                if endedActivityIds.contains(activity.id) { continue }
                if let reason = Self.endReason(
                    for: Self.makeFacts(activity),
                    now: now,
                    isAvailable: isAvailable(),
                    isQuietDay: isQuietDay,
                    isAssignmentOutstanding: isAssignmentOutstanding,
                    isSkipped: isSkipped
                ) {
                    await end(activity, reason: reason.rawValue)
                    continue
                }
                observeUpdateToken(for: activity)
                scheduleAutomaticEnd(
                    for: activity.attributes.activityId,
                    snapshot: activity.content.state.snapshot,
                    now: now
                )
            }
        }
    }

    private func pruneRunningActivities(now: Date) async {
        let available = isAvailable()
        endedActivityIds = endedActivityIds.intersection(
            Activity<TigerDuckActivityAttributes>.activities.map(\.id)
        )
        if available {
            await endDuplicateActivities(now: now)
        }
        let listed = Activity<TigerDuckActivityAttributes>.activities
        var retainedTaskIds: Set<String> = []
        for activity in listed {
            if endedActivityIds.contains(activity.id) { continue }
            let activityId = activity.attributes.activityId

            if let reason = Self.endReason(
                for: Self.makeFacts(activity),
                now: now,
                isAvailable: available,
                isQuietDay: isQuietDay,
                isAssignmentOutstanding: isAssignmentOutstanding,
                isSkipped: isSkipped
            ) {
                await end(activity, reason: reason.rawValue)
            } else {
                retainedTaskIds.insert(activityId)
                observeUpdateToken(for: activity)
                scheduleAutomaticEnd(
                    for: activityId,
                    snapshot: activity.content.state.snapshot,
                    now: now
                )
            }
        }
        cancelAutomaticEndTasks(except: retainedTaskIds)
        cancelUpdateTokenTasks(except: retainedTaskIds)
    }

    nonisolated static func makeFacts(
        _ activity: Activity<TigerDuckActivityAttributes>
    ) -> RunningActivityFacts {
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

    nonisolated struct RunningActivityFacts: Equatable, Sendable {
        let instanceId: String
        let activityId: String
        let sourceId: String
        let scenario: LiveActivityScenarioKind
        let countdownTarget: Date?
        let hasPushToken: Bool
        let isLive: Bool
    }

    nonisolated static func expiredInstanceIds(
        _ facts: [RunningActivityFacts],
        now: Date
    ) -> [String] {
        facts
            .filter { $0.countdownTarget.map { $0 <= now } ?? false }
            .map(\.instanceId)
    }

    nonisolated static func instanceIdsToEnd(
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

    nonisolated enum EndReason: String, Sendable {
        case unavailable = "Live Activity unavailable"
        case expired = "countdown expired"
        case quietDay = "classes do not meet that day"
        case skippedClass = "class skipped that day"
        case assignmentDone = "assignment submitted, ignored or marked done"
    }

    nonisolated static func endReason(
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

    nonisolated static func quietClassInstanceIds(
        _ facts: [RunningActivityFacts],
        isQuietDay: (Date) -> Bool
    ) -> [String] {
        facts
            .filter {
                isQuietClass($0.scenario, countdownTarget: $0.countdownTarget, isQuietDay: isQuietDay)
            }
            .map(\.instanceId)
    }

    nonisolated static func isQuietClass(
        _ scenario: LiveActivityScenarioKind,
        countdownTarget: Date?,
        isQuietDay: (Date) -> Bool
    ) -> Bool {
        [.classPreparing, .inClass].contains(scenario)
            && (countdownTarget.map(isQuietDay) ?? false)
    }

    nonisolated static func isSkippedClass(
        _ scenario: LiveActivityScenarioKind,
        sourceId: String,
        isSkipped: (String) -> Bool
    ) -> Bool {
        [.classPreparing, .inClass].contains(scenario) && isSkipped(sourceId)
    }

    nonisolated static func isDoneAssignment(
        _ scenario: LiveActivityScenarioKind,
        sourceId: String,
        isAssignmentOutstanding: (String) -> Bool?
    ) -> Bool {
        scenario == .assignmentUrgent && isAssignmentOutstanding(sourceId) == false
    }

    nonisolated static func canStart(
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

    nonisolated static func duplicateInstanceIdsToEnd(
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

    private func endDuplicateActivities(now: Date) async {
        let listed = Activity<TigerDuckActivityAttributes>.activities
        let live = listed.filter {
            ($0.activityState == .active || $0.activityState == .stale)
                && !endedActivityIds.contains($0.id)
        }
        let toEnd = Set(Self.duplicateInstanceIdsToEnd(live.map(Self.makeFacts)))
        guard !toEnd.isEmpty else { return }

        for (activityId, copies) in Dictionary(
            grouping: live, by: { $0.attributes.activityId }
        ) {
            let doomed = copies.filter { toEnd.contains($0.id) }
            guard !doomed.isEmpty,
                  let keeper = copies.first(where: { !toEnd.contains($0.id) })
            else { continue }
            for copy in doomed {
                logger.info(
                    "Ending duplicate Live Activity id=\(activityId, privacy: .private) reason=already running"
                )
                endedActivityIds.insert(copy.id)
                await copy.end(nil, dismissalPolicy: .immediate)
            }
            activityUpdateTokenTasks[activityId]?.cancel()
            activityUpdateTokenTasks[activityId] = nil
            observeUpdateToken(for: keeper)
            scheduleAutomaticEnd(
                for: activityId,
                snapshot: keeper.content.state.snapshot,
                now: now
            )
        }
    }

    private func scheduleAutomaticEnd(
        for activityId: String,
        snapshot: LiveActivitySnapshot,
        now: Date
    ) {
        automaticEndTasks[activityId]?.cancel()

        guard let target = snapshot.countdownTarget else {
            automaticEndTasks[activityId] = nil
            return
        }

        let realTarget = AppClock.realTime(forApp: target)
        let delay = max(0, realTarget.timeIntervalSinceNow) + 1
        automaticEndTasks[activityId] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.endIfStillExpired(activityId: activityId, target: target)
        }
    }

    private func endIfStillExpired(activityId: String, target: Date) async {
        automaticEndTasks[activityId] = nil
        guard AppClock.now() >= target,
              let activity = Activity<TigerDuckActivityAttributes>.activities.first(where: {
                  $0.attributes.activityId == activityId && !endedActivityIds.contains($0.id)
              }) else {
            return
        }
        await end(activity, reason: "automatic countdown end")
    }

    private func end(
        _ activity: Activity<TigerDuckActivityAttributes>,
        reason: String
    ) async {
        let activityId = activity.attributes.activityId
        logger.info(
            "Ending Live Activity id=\(activityId, privacy: .private) reason=\(reason, privacy: .public)"
        )
        endedActivityIds.insert(activity.id)
        await activity.end(nil, dismissalPolicy: .immediate)
        automaticEndTasks[activityId]?.cancel()
        automaticEndTasks[activityId] = nil
        activityUpdateTokenTasks[activityId]?.cancel()
        activityUpdateTokenTasks[activityId] = nil
    }

    private func cancelAutomaticEndTasks(except retainedIds: Set<String> = []) {
        for activityId in Array(automaticEndTasks.keys) where !retainedIds.contains(activityId) {
            automaticEndTasks[activityId]?.cancel()
            automaticEndTasks[activityId] = nil
        }
    }

    private func observeUpdateToken(for activity: Activity<TigerDuckActivityAttributes>) {
        let activityId = activity.attributes.activityId
        guard activityUpdateTokenTasks[activityId] == nil else { return }
        activityUpdateTokenTasks[activityId] = Task { @MainActor [weak self] in
            await self?.registerCurrentUpdateToken(for: activity)
            for await tokenData in activity.pushTokenUpdates {
                guard !Task.isCancelled else { return }
                await self?.registerUpdateToken(
                    activityId: activityId,
                    tokenData: tokenData,
                    snapshot: activity.content.state.snapshot
                )
            }
            guard !Task.isCancelled else { return }
            self?.activityUpdateTokenTasks[activityId] = nil
        }
    }

    private func registerCurrentUpdateToken(
        for activity: Activity<TigerDuckActivityAttributes>
    ) async {
        guard let tokenData = activity.pushToken else { return }
        await registerUpdateToken(
            activityId: activity.attributes.activityId,
            tokenData: tokenData,
            snapshot: activity.content.state.snapshot
        )
    }

    private func registerUpdateToken(
        activityId: String,
        tokenData: Data,
        snapshot: LiveActivitySnapshot
    ) async {
        guard let updateTokenRegistrationHandler, isAvailable() else { return }
        let tokenHex = tokenData.hexEncodedString()
        await updateTokenRegistrationHandler(
            LiveActivityUpdateTokenRegistration(
                activityId: activityId,
                updateTokenHex: tokenHex,
                snapshot: snapshot
            )
        )
    }

    private func cancelUpdateTokenTasks(except retainedIds: Set<String> = []) {
        for activityId in Array(activityUpdateTokenTasks.keys) where !retainedIds.contains(activityId) {
            activityUpdateTokenTasks[activityId]?.cancel()
            activityUpdateTokenTasks[activityId] = nil
        }
    }
}
