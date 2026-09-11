import ActivityKit
import Foundation
import os

nonisolated struct LiveActivityUpdateTokenRegistration: Sendable {
    let activityId: String
    let updateTokenHex: String
    let snapshot: LiveActivitySnapshot
}

/// Reflects a resolved `LiveActivitySnapshot` as one running
/// `TigerDuckActivityAttributes` activity among whatever else is running.
///
/// Scenario-scoped `activityId` (`snapshot.composedActivityId`) is the
/// single source of truth for identity. It keeps the on-device path and
/// the server-push path consistent: a classPreparing activity and its
/// follow-up inClass activity are distinct to ActivityKit, so PTS from
/// the server can start the inClass one without colliding with the
/// classPreparing one that iOS already has running.
///
/// 這個 coordinator **不**維持「同時只有一個活動」的 invariant。ActivityKit
/// 不把 `staleDate` 當結束訊號，所以每次前景刷新仍會結束倒數已過的活動、
/// 以及同一個 `activityId` 的重複副本；但「不是當下解析目標」**不是**結束理由。
///
/// 這一點翻過一次：d7843a2（2026-04-22）移除 prune，理由是伺服器
/// push-to-start 會預先啟動未來時段的 classPreparing 活動，而 resolver
/// 一次只回傳單一 snapshot，導致 App 一進前景就把預排的活動全部殺掉；
/// b8d8ca9（2026-04-24）兩天後又整段加回來以解決「過期活動賴著不走」。
/// 現行設計同時滿足兩者：逾期與重複照樣清理，非當前目標則放著不動，
/// 由伺服器排定的 end job 或其自身的倒數收尾。
/// 決策邏輯抽在 `expiredInstanceIds` / `duplicateInstanceIdsToEnd`，
/// 由 `LiveActivityCoordinatorTests` 釘住。詳見 spec §4.3。
/// 但釘住的只是這兩個決策函式本身，不是 `pruneRunningActivities` 這個迴圈：
/// 迴圈裡若被插回一段 `else if !isCurrentTarget { await end(...) }`，
/// 八個測試依然全線通過——迴圈怎麼使用這兩個函式的結果，測試套件看不到。
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
    /// out. Pruned of ids ActivityKit no longer lists.
    private var endedActivityIds: Set<String> = []
    private var updateTokenRegistrationHandler: (@Sendable (LiveActivityUpdateTokenRegistration) async -> Void)?

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

    /// Apply the resolved snapshot. Starts or updates the single activity
    /// matching the target id, and ends only activities that are expired or
    /// duplicates; an activity that is not the current target is left running.
    func apply(snapshot: LiveActivitySnapshot?) async {
        let now = AppClock.now()
        await pruneRunningActivities(now: now)

        // Persist the snapshot to the App Group AFTER the system gate so
        // a user with Live Activities disabled cannot leave a stale
        // snapshot in shared storage that any background widget read
        // would still surface. When disabled — or no snapshot — we
        // explicitly clear the share so reads see exactly what the
        // user expects.
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            logger.info("Live Activities are disabled by the system")
            store.writeSnapshot(nil)
            return
        }

        guard let snapshot else {
            store.writeSnapshot(nil)
            // Nothing to cancel here: `pruneRunningActivities` above already
            // cancelled every automatic-end timer except the survivors'
            // (`except: retainedTaskIds`), and those survivors are running
            // activities this coordinator is deliberately leaving alone —
            // not being the current target does not mean "end it". An
            // unconditional `cancelAutomaticEndTasks()` here would strand
            // every one of them with no timer left to end it. Do not add
            // it back.
            return
        }

        store.writeSnapshot(snapshot)

        let targetId = snapshot.composedActivityId
        let runningActivities = Activity<TigerDuckActivityAttributes>.activities

        let state = TigerDuckActivityAttributes.ContentState(snapshot: snapshot)
        // `staleDate` is OS-consumed and validated against the real wall
        // clock — passing the raw app-clock `countdownTarget` makes
        // `Activity.request` fail with `ActivityInput error 0` whenever
        // the debug clock points at a real-future date (the staleDate
        // would land days away). Translate to the real instant that maps
        // to the same fake-clock end so the system sees a sensible
        // short-horizon stale marker.
        let realStaleDate = snapshot.countdownTarget.map(AppClock.realTime(forApp:))
        let content = ActivityContent(state: state, staleDate: realStaleDate)

        // A copy this coordinator has just ended can still be listed; it
        // is not the one to update. One the system or the user ended is:
        // updating it is a no-op, and that is the point — the person got
        // rid of it, and the app must not put it back.
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
                    // Only request a push token when a server-side handler
                    // is wired up to receive it. Otherwise APNs would mint
                    // tokens nothing consumes — and a missing handler is
                    // the legitimate state for users without push enabled.
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
                let snapshot = activity.content.state.snapshot
                let facts = Self.makeFacts(activity)
                if Self.expiredInstanceIds([facts], now: now).contains(facts.instanceId) {
                    await end(activity, reason: "observed expired activity")
                } else {
                    observeUpdateToken(for: activity)
                    scheduleAutomaticEnd(
                        for: activity.attributes.activityId,
                        snapshot: snapshot,
                        now: now
                    )
                }
            }
        }
    }

    private func pruneRunningActivities(now: Date) async {
        await endDuplicateActivities(now: now)
        // 一次取樣後重複使用。分兩次讀 `Activity.activities` 會讓逾期判定
        // 與實際迴圈看到不同的清單。
        let listed = Activity<TigerDuckActivityAttributes>.activities
        let expired = Set(
            Self.expiredInstanceIds(listed.map(Self.makeFacts), now: now)
        )
        var retainedTaskIds: Set<String> = []
        for activity in listed {
            // 上面已經結束、但仍被列出的副本：對它呼叫 `end(_:reason:)`
            // 會把留存者的 observer 一起拔掉，兩者共用同一個 activityId。
            if endedActivityIds.contains(activity.id) { continue }
            let activityId = activity.attributes.activityId

            if expired.contains(activity.id) {
                await end(activity, reason: "countdown expired")
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

    // MARK: - 純決策（不接觸 ActivityKit，供單元測試使用）

    /// 把一個 ActivityKit 活動壓成純事實值。
    nonisolated static func makeFacts(
        _ activity: Activity<TigerDuckActivityAttributes>
    ) -> RunningActivityFacts {
        RunningActivityFacts(
            instanceId: activity.id,
            activityId: activity.attributes.activityId,
            countdownTarget: activity.content.state.snapshot.countdownTarget,
            hasPushToken: activity.pushToken != nil,
            isLive: activity.activityState == .active
                || activity.activityState == .stale
        )
    }

    /// `prune` 需要知道的、關於一個執行中活動的全部事實。
    ///
    /// 從 ActivityKit 抬起來成為普通值型別，讓下面的決策函式可以在沒有
    /// ActivityKit 的環境下被單元測試——與 `ScheduleSyncService.buildEvents`
    /// 相同的純工廠慣例。
    nonisolated struct RunningActivityFacts: Equatable, Sendable {
        /// `Activity.id`——同一個 `activityId` 可能有多個副本。
        let instanceId: String
        /// `attributes.activityId`——場景範圍的身分。
        let activityId: String
        let countdownTarget: Date?
        /// APNs 是否已為這個副本鑄出 update token。
        let hasPushToken: Bool
        /// `activityState` 是 `.active` 或 `.stale`。
        let isLive: Bool
    }

    /// 應當因倒數已過而結束的 `Activity.id`。
    ///
    /// 只看倒數，不看「是不是當下解析出來的目標」。伺服器 push-to-start
    /// 會預先啟動未來時段的活動，而 resolver 一次只回傳單一 snapshot，
    /// 所以用「非當前目標」當結束條件會把預排的活動全部殺掉。詳見 spec §4.3。
    nonisolated static func expiredInstanceIds(
        _ facts: [RunningActivityFacts],
        now: Date
    ) -> [String] {
        facts
            .filter { $0.countdownTarget.map { $0 <= now } ?? false }
            .map(\.instanceId)
    }

    /// 同一個 `activityId` 有多份 live 副本時，應當結束的那些 `Activity.id`。
    ///
    /// 留下的是 APNs 已鑄出 update token 的那一份——它才是伺服器搆得到的；
    /// 都沒有 token 時退回 `instanceId` 最小者，讓結果可預測。
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
    /// A push-to-start can land for an activity this app already started
    /// itself: it was in the foreground at fire time, so `apply` got there
    /// first. The server skips the push while the activity is registered,
    /// but registration is a round trip and the two can cross. `apply` and
    /// the activity observer both run through here, so a pair is resolved on
    /// whichever comes first.
    ///
    /// The copy whose update token APNs has already minted is kept — it is
    /// the one the server can reach — and the token observer and end timer
    /// are re-pointed at it, because both are keyed by `activityId` and may
    /// still describe a copy that just went away. An observer left on a
    /// dead activity means the survivor's token is never registered, so the
    /// server can neither end it nor see it running. Extras are ended
    /// directly rather than through `end(_:reason:)`, which would drop those
    /// keys instead of re-pointing them.
    private func endDuplicateActivities(now: Date) async {
        let listed = Activity<TigerDuckActivityAttributes>.activities
        endedActivityIds = endedActivityIds.intersection(listed.map(\.id))
        // `isLive` 的過濾在這裡做完，下面挑 keeper 時才不會選到已經
        // dismissed 的副本。`duplicateInstanceIdsToEnd` 內部也會再濾一次，
        // 但那是為了讓純函式自身的契約完整，兩者不衝突。
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
            // observer 與 end timer 都以 activityId 為鍵，可能仍指向剛消失的
            // 副本；重新指向留存者，否則它的 token 永遠不會註冊，伺服器既
            // 結束不了也看不到它在跑。
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

        // `Task.sleep` runs on the real clock, so translate the fake-clock
        // target to the real instant it maps to. Captured once per the
        // `AppClock.realTime(forApp:)` contract — re-deriving in frozen
        // mode would drift as real time advances while fake time stands
        // still.
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
        // Skip if we're already observing this activity. The previous
        // implementation also fired an unconditional fire-and-forget
        // registration Task on every call — `observeUpdateToken` is
        // invoked from `apply`, `pruneRunningActivities`, and the
        // activity observer's loop, so server registration was hit
        // O(refresh × activities) times per session. The gated stream
        // below already drains `pushTokenUpdates` *and* registers the
        // current token on first iteration, so the unconditional
        // re-register is redundant.
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
            // The stream ends with the activity. Leave the slot free so a
            // later activity under the same id (the same class next week,
            // started by push) is observed rather than turned away by the
            // guard above. A cancelled task has been replaced already and
            // must not clear its successor.
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
        guard let updateTokenRegistrationHandler else { return }
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
