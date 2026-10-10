import ActivityKit
import Foundation
import os

nonisolated struct LiveActivityUpdateTokenRegistration: Sendable {
    let activityId: String
    let updateTokenHex: String
    let snapshot: LiveActivitySnapshot
    /// `snapshot.countdownTarget` in real wall-clock time, converted once here
    /// rather than at each send. Under a frozen debug clock the conversion is
    /// "real now plus the remaining fake interval", so recomputing it on a
    /// retry would push the server's end job out by the whole backoff — a
    /// target ten fake minutes away stays ten minutes away forever.
    let countdownTargetRealTime: Date?

    init(activityId: String, updateTokenHex: String, snapshot: LiveActivitySnapshot) {
        self.activityId = activityId
        self.updateTokenHex = updateTokenHex
        self.snapshot = snapshot
        countdownTargetRealTime = snapshot.countdownTarget.map(AppClock.realTime(forApp:))
    }
}

/// Reflects a resolved `LiveActivitySnapshot` as one running
/// `TigerDuckActivityAttributes` activity among whatever else is running.
///
/// Identity is the scenario-scoped `snapshot.composedActivityId` on device and push paths alike,
/// so a pushed inClass activity does not collide with the classPreparing one already running.
/// ActivityKit does not end an activity at `staleDate`, so the prune ends the ones `endReason`
/// and `duplicateInstanceIdsToEnd` pick. Not being the current target is never a reason to end.
/// Tests pin these, not the prune loop. See docs/decisions/0010-live-activity-end-policy.md.
@MainActor
final class LiveActivityCoordinator {
    private let store: SharedSnapshotStore
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "LiveActivity")
    private var automaticEndTasks: [String: Task<Void, Never>] = [:]
    private var activityObserverTask: Task<Void, Never>?
    private var activityUpdateTokenTasks: [String: Task<Void, Never>] = [:]
    /// `Activity.id`s this coordinator has ended. ActivityKit does not
    /// promise that an ended activity has left `Activity.activities` by the
    /// time `end` returns, so a survivor search that trusted
    /// `activityState` alone could pick a copy that is already on its way
    /// out. Pruned of ids ActivityKit no longer lists, on every pass of
    /// `pruneRunningActivities` — including the passes that run while Live
    /// Activity is unavailable, which is when the ending happens wholesale.
    private var endedActivityIds: Set<String> = []
    private var updateTokenRegistrationHandler: (@Sendable (LiveActivityUpdateTokenRegistration) async -> Void)?
    /// Whether Live Activity may run at all right now —
    /// `effectiveLiveActivityEnabled`, supplied by `AppState`. The prune and
    /// the activity observer ask it on every pass, so an activity the server
    /// starts after the rule turned off, from a schedule uploaded before, is
    /// ended when it shows up instead of running to its own countdown.
    /// `true` until `AppState` installs the real answer.
    private var isAvailable: () -> Bool = { true }
    /// Whether classes do not meet on a day, with this user's "still have
    /// class" choices — `AcademicCalendarStore`'s answer, supplied by
    /// `AppState`. Asked on the same passes as `isAvailable`, so a class
    /// activity on screen for a day that has turned quiet is ended rather
    /// than left to its countdown. `false` until `AppState` installs it.
    private var isQuietDay: (Date) -> Bool = { _ in false }

    init(store: SharedSnapshotStore = SharedSnapshotStore()) {
        self.store = store
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

    /// Apply the resolved snapshot. Starts or updates the single activity
    /// matching the target id, and ends only activities that are expired,
    /// duplicates, or classes on a day classes do not meet; an activity that
    /// is not the current target is left running.
    /// While Live Activity is unavailable it ends every activity instead, and
    /// starts none.
    func apply(snapshot: LiveActivitySnapshot?) async {
        let now = AppClock.now()
        await pruneRunningActivities(now: now)

        // Write the snapshot to the App Group only after the system gate, and clear it when
        // Live Activities are disabled or there is no snapshot, so a background widget read
        // never surfaces a stale snapshot.
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            logger.info("Live Activities are disabled by the system")
            store.writeSnapshot(nil)
            return
        }

        // The snapshot was resolved before the prune's await. Recheck, so one resolved just before
        // Live Activity turned unavailable, or before its class day turned quiet (a "still have
        // class" toggle, a newly published holiday), does not start an activity.
        guard let snapshot,
              Self.canStart(snapshot, isAvailable: isAvailable(), isQuietDay: isQuietDay)
        else {
            store.writeSnapshot(nil)
            // No `cancelAutomaticEndTasks()` here: the prune already cancelled every timer but the
            // survivors', and a survivor that is not the current target keeps running, so it
            // would be stranded with no timer left to end it.
            return
        }

        store.writeSnapshot(snapshot)

        let targetId = snapshot.composedActivityId
        let runningActivities = Activity<TigerDuckActivityAttributes>.activities

        let state = TigerDuckActivityAttributes.ContentState(snapshot: snapshot)
        // The OS checks `staleDate` against the real clock. The raw app-clock `countdownTarget`,
        // under a debug clock set to a future date, makes `Activity.request` fail with
        // `ActivityInput error 0`; pass the real instant that maps to the same fake-clock end.
        let realStaleDate = snapshot.countdownTarget.map(AppClock.realTime(forApp:))
        let content = ActivityContent(state: state, staleDate: realStaleDate)

        // Skip a copy this coordinator just ended, which ActivityKit can still list. One the
        // system or the user ended still matches: updating it is a no-op, and the app must not
        // put back an activity the person got rid of.
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
                    // Request a push token only when a handler is set to send it to the server;
                    // otherwise APNs mints unused tokens. A nil handler is the normal state for
                    // users without push enabled.
                    pushType: updateTokenRegistrationHandler == nil ? nil : .token
                )
                observeUpdateToken(for: activity)
                scheduleAutomaticEnd(for: targetId, snapshot: snapshot, now: now)
            } catch {
                logger.error("Failed to start Live Activity: \(error.localizedDescription, privacy: .public)")
                AppLogger.captureError(error, context: [
                    "phase": "liveActivity.requestStart",
                    "activityId": targetId,
                ])
            }
        }
    }

    /// End every running activity unconditionally. Used for logout and
    /// explicit privacy toggles — the user wants nothing on their lock
    /// screen, server-pushed or otherwise.
    func endAll() async {
        for activity in Activity<TigerDuckActivityAttributes>.activities {
            await end(activity, reason: "endAll")
        }
        cancelAutomaticEndTasks()
        cancelUpdateTokenTasks()
        store.writeSnapshot(nil)
    }

    private func startActivityObserver() {
        activityObserverTask = Task { @MainActor [weak self] in
            for await activity in Activity<TigerDuckActivityAttributes>.activityUpdates {
                guard let self else { return }
                let now = AppClock.now()
                await pruneRunningActivities(now: now)
                // A push-to-start twin of an activity this app already
                // started is ended inside the prune; nothing below is for it.
                if endedActivityIds.contains(activity.id) { continue }
                // The server may start one from a schedule uploaded before Live Activity turned
                // unavailable, or a class on a day that turned quiet since. End it on arrival and
                // never register its token; the prune above may not have listed it yet.
                if let reason = Self.endReason(
                    for: Self.makeFacts(activity),
                    now: now,
                    isAvailable: isAvailable(),
                    isQuietDay: isQuietDay
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
        // Trim here, outside the availability check: `end(_:reason:)` also records the wholesale
        // ends while unavailable. Trim before this pass ends any, so a copy ended now stays in the
        // set for the observer loop's `contains` check after it leaves `Activity.activities`.
        endedActivityIds = endedActivityIds.intersection(
            Activity<TigerDuckActivityAttributes>.activities.map(\.id)
        )
        // Skipped while unavailable: the loop below ends everything, so resolving duplicates
        // first would only re-point the token observer at a survivor about to be ended.
        if available {
            await endDuplicateActivities(now: now)
        }
        // Sampled once so the end decisions and the loop see the same list.
        let listed = Activity<TigerDuckActivityAttributes>.activities
        var retainedTaskIds: Set<String> = []
        for activity in listed {
            // Skip a copy already ended above but still listed: `end(_:reason:)` on it would also
            // drop the survivor's observer, which shares its activityId.
            if endedActivityIds.contains(activity.id) { continue }
            let activityId = activity.attributes.activityId

            if let reason = Self.endReason(
                for: Self.makeFacts(activity),
                now: now,
                isAvailable: available,
                isQuietDay: isQuietDay
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

    // MARK: - Pure decisions (no ActivityKit, for unit tests)

    /// Flattens an ActivityKit activity into plain facts.
    nonisolated static func makeFacts(
        _ activity: Activity<TigerDuckActivityAttributes>
    ) -> RunningActivityFacts {
        RunningActivityFacts(
            instanceId: activity.id,
            activityId: activity.attributes.activityId,
            scenario: activity.content.state.snapshot.scenario,
            countdownTarget: activity.content.state.snapshot.countdownTarget,
            hasPushToken: activity.pushToken != nil,
            isLive: activity.activityState == .active
                || activity.activityState == .stale
        )
    }

    /// Everything the prune needs to know about one running activity.
    ///
    /// A plain value lifted out of ActivityKit, so the decisions below can be unit-tested
    /// without it, following the pure-factory convention of `ScheduleSyncService.buildEvents`.
    nonisolated struct RunningActivityFacts: Equatable, Sendable {
        /// `Activity.id`. One `activityId` can have several copies.
        let instanceId: String
        /// `attributes.activityId`, the scenario-scoped identity.
        let activityId: String
        /// Only class scenarios (classPreparing, inClass) end on a day classes do not meet.
        let scenario: LiveActivityScenarioKind
        let countdownTarget: Date?
        /// Whether APNs has minted an update token for this copy.
        let hasPushToken: Bool
        /// `activityState` is `.active` or `.stale`.
        let isLive: Bool
    }

    /// The `Activity.id`s whose countdown has passed.
    ///
    /// Only the countdown counts, not whether the activity is the current resolved target:
    /// server push-to-start pre-starts later activities and the resolver returns one snapshot,
    /// so ending every non-target would kill all the pre-started ones.
    nonisolated static func expiredInstanceIds(
        _ facts: [RunningActivityFacts],
        now: Date
    ) -> [String] {
        facts
            .filter { $0.countdownTarget.map { $0 <= now } ?? false }
            .map(\.instanceId)
    }

    /// The `Activity.id`s the prune should end; the batch form of `endReason`.
    ///
    /// While Live Activity is available: `expiredInstanceIds` plus `quietClassInstanceIds`, with
    /// `isQuietDay` the academic-calendar answer from `AppState`. While it is unavailable (course
    /// sync off or the user's own switch off, see `effectiveLiveActivityEnabled`): all of them,
    /// even ones the server pre-started whose countdown is still ahead, because the server starts
    /// them from the schedule the device uploaded before and does not enforce this rule.
    nonisolated static func instanceIdsToEnd(
        _ facts: [RunningActivityFacts],
        now: Date,
        isAvailable: Bool,
        isQuietDay: (Date) -> Bool = { _ in false }
    ) -> [String] {
        facts
            .filter {
                endReason(for: $0, now: now, isAvailable: isAvailable, isQuietDay: isQuietDay) != nil
            }
            .map(\.instanceId)
    }

    /// Why an activity is ended; the raw value is the string written to the log.
    nonisolated enum EndReason: String, Sendable {
        case unavailable = "Live Activity unavailable"
        case expired = "countdown expired"
        case quietDay = "classes do not meet that day"
    }

    /// Whether an activity should end, and why; `nil` keeps it.
    ///
    /// The prune and the observer of new activities both act on this alone: an activity with a
    /// reason is ended, and only one without gets its update token registered and its countdown
    /// end scheduled. While unavailable every activity ends; while available, expired ones and
    /// class activities on a day classes do not meet (`quietClassInstanceIds`).
    nonisolated static func endReason(
        for fact: RunningActivityFacts,
        now: Date,
        isAvailable: Bool,
        isQuietDay: (Date) -> Bool
    ) -> EndReason? {
        if !isAvailable { return .unavailable }
        if !expiredInstanceIds([fact], now: now).isEmpty { return .expired }
        if !quietClassInstanceIds([fact], isQuietDay: isQuietDay).isEmpty { return .quietDay }
        return nil
    }

    /// `Activity.id`s of class activities (classPreparing, inClass) on days classes do not meet.
    ///
    /// The server checks holidays only when it sends a push, so it cannot stop an activity already
    /// on screen: a typhoon day announced after the push, or "still have class" switched off after
    /// the activity appeared. The day comes from the countdown target (class start before class,
    /// class end during it), which falls on the class day and is the field the backend reads.
    /// Without a countdown target there is nothing to judge, so the activity stays. Assignment
    /// activities stay too: a deadline on a holiday is still a deadline.
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

    /// A class scenario (classPreparing, inClass) with its countdown target on a quiet day.
    nonisolated static func isQuietClass(
        _ scenario: LiveActivityScenarioKind,
        countdownTarget: Date?,
        isQuietDay: (Date) -> Bool
    ) -> Bool {
        [.classPreparing, .inClass].contains(scenario)
            && (countdownTarget.map(isQuietDay) ?? false)
    }

    /// The last check before `apply` starts or updates `snapshot`: Live Activity is available and
    /// the snapshot is not a class on a quiet day. Asked after the prune's await, because the
    /// snapshot was resolved before it; a "still have class" toggle or a holiday published in
    /// between is caught here instead of at the next prune.
    nonisolated static func canStart(
        _ snapshot: LiveActivitySnapshot,
        isAvailable: Bool,
        isQuietDay: (Date) -> Bool
    ) -> Bool {
        isAvailable
            && !isQuietClass(
                snapshot.scenario,
                countdownTarget: snapshot.countdownTarget,
                isQuietDay: isQuietDay
            )
    }

    /// The `Activity.id`s to end when one `activityId` has several live copies.
    ///
    /// Keeps a copy APNs has minted an update token for, since only that one is reachable by the
    /// server; without any token, the lowest `instanceId`, so the result is predictable.
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

    /// Keeps one copy of every `activityId` and ends the rest.
    ///
    /// A push-to-start can land for an activity `apply` already started in the foreground: the
    /// server skips the push for a registered activity, but registration is a round trip and the
    /// two can cross. `apply` and the activity observer both run this; the first resolves the pair.
    /// The token observer and end timer, keyed by `activityId`, are re-pointed at the keeper. Left
    /// on a dead copy, the observer never registers the keeper's token, so the server can neither
    /// end it nor see it. Extras are ended directly: `end(_:reason:)` would drop those keys.
    private func endDuplicateActivities(now: Date) async {
        let listed = Activity<TigerDuckActivityAttributes>.activities
        // Filter to live copies here so the keeper picked below is never a dismissed one.
        // `duplicateInstanceIdsToEnd` filters again to keep its own contract; the two agree.
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
                    "Ending duplicate Live Activity id=\(activityId, privacy: .public) reason=already running"
                )
                endedActivityIds.insert(copy.id)
                await copy.end(nil, dismissalPolicy: .immediate)
            }
            // The token observer and end timer are keyed by activityId and may still point at an
            // ended copy. Re-point them, or the keeper's token never registers and the server can
            // neither end it nor see it running.
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

        // `Task.sleep` runs on the real clock, so convert the fake-clock target to its real
        // instant once, per the `AppClock.realTime(forApp:)` contract: re-deriving it in frozen
        // mode drifts, as real time advances while fake time stands still.
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
        // Not a copy already ended: `end(_:reason:)` on it would drop the
        // keeper's observer, which shares its activityId.
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
            "Ending Live Activity id=\(activityId, privacy: .public) reason=\(reason, privacy: .public)"
        )
        // Record before the await: ActivityKit can still list an ended copy, and an unrecorded one
        // is picked up again. `apply` would update it instead of starting a fresh activity, and
        // the prune would re-register its token, which tells the server the activity still runs.
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
        // One observer per activityId: `apply`, the prune and the activity observer call this on
        // every pass, so registering on each call would hit the server per refresh per activity.
        // The task below registers the current token once, then follows `pushTokenUpdates`.
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
            // The stream ends with the activity. Free the slot so a later activity under the same
            // id (next week's class, started by push) is not turned away by the guard above. A
            // cancelled task has been replaced already and must not clear its successor.
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
        // Never while Live Activity is unavailable: a registered token is
        // what lets the server keep pushing to an activity this device is
        // ending.
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
