import Foundation
import Testing
@testable import TigerDuck

/// 釘住動態島的併存 invariant。
///
/// 這條 invariant 曾經翻過一次：d7843a2（2026-04-22）移除了 prune，
/// b8d8ca9（2026-04-24）兩天後又整段加回來，而當時沒有任何測試擋得住。
/// 若這些測試開始失敗，請先讀 spec §4.3 再決定要改程式還是改測試。
@MainActor
struct LiveActivityCoordinatorTests {

    private static let now = Date(timeIntervalSince1970: 1_757_500_000)

    private static func facts(
        instanceId: String,
        activityId: String,
        countdownTarget: Date?,
        hasPushToken: Bool = false,
        isLive: Bool = true
    ) -> LiveActivityCoordinator.RunningActivityFacts {
        .init(
            instanceId: instanceId,
            activityId: activityId,
            countdownTarget: countdownTarget,
            hasPushToken: hasPushToken,
            isLive: isLive
        )
    }

    // MARK: - 逾期判定

    @Test("伺服器預排的未來時段活動不會因為『不是當下目標』而被結束")
    func futurePrelaunchedActivitiesSurvive() {
        // A 課進行中（30 分鐘後下課），B 課的 classPreparing 已由
        // push-to-start 預先啟動（2 小時後開始）。resolver 一次只會回傳
        // 其中一個，舊行為會把另一個殺掉。
        let running = Self.facts(
            instanceId: "i1",
            activityId: "inClass-A",
            countdownTarget: Self.now.addingTimeInterval(1800)
        )
        let prelaunched = Self.facts(
            instanceId: "i2",
            activityId: "classPreparing-B",
            countdownTarget: Self.now.addingTimeInterval(7200)
        )

        let ended = LiveActivityCoordinator.expiredInstanceIds(
            [running, prelaunched],
            now: Self.now
        )

        #expect(ended.isEmpty)
    }

    @Test("倒數已過的活動會被結束")
    func expiredActivityIsEnded() {
        let expired = Self.facts(
            instanceId: "i1",
            activityId: "inClass-A",
            countdownTarget: Self.now.addingTimeInterval(-1)
        )
        let live = Self.facts(
            instanceId: "i2",
            activityId: "inClass-B",
            countdownTarget: Self.now.addingTimeInterval(600)
        )

        let ended = LiveActivityCoordinator.expiredInstanceIds(
            [expired, live],
            now: Self.now
        )

        #expect(ended == ["i1"])
    }

    @Test("倒數目標剛好等於現在視為已過期")
    func countdownTargetAtNowIsExpired() {
        let boundary = Self.facts(
            instanceId: "i1",
            activityId: "inClass-A",
            countdownTarget: Self.now
        )

        let ended = LiveActivityCoordinator.expiredInstanceIds(
            [boundary],
            now: Self.now
        )

        #expect(ended == ["i1"])
    }

    @Test("沒有倒數目標的活動不會被逾期判定結束")
    func nilCountdownTargetSurvives() {
        let noTarget = Self.facts(
            instanceId: "i1",
            activityId: "inClass-A",
            countdownTarget: nil
        )

        let ended = LiveActivityCoordinator.expiredInstanceIds(
            [noTarget],
            now: Self.now
        )

        #expect(ended.isEmpty)
    }

    // MARK: - 重複副本

    @Test("同一個 activityId 有兩份時，保留 APNs 已鑄出 token 的那一份")
    func duplicateKeepsCopyWithPushToken() {
        let withToken = Self.facts(
            instanceId: "i2",
            activityId: "inClass-A",
            countdownTarget: Self.now.addingTimeInterval(600),
            hasPushToken: true
        )
        let withoutToken = Self.facts(
            instanceId: "i1",
            activityId: "inClass-A",
            countdownTarget: Self.now.addingTimeInterval(600),
            hasPushToken: false
        )

        // 刻意把該保留的那份放在後面：「一律留第一份」的實作會在這裡失敗。
        let ended = LiveActivityCoordinator.duplicateInstanceIdsToEnd(
            [withoutToken, withToken]
        )

        // 即使 i1 的 instanceId 較小，有 token 的 i2 仍勝出——
        // 它才是伺服器搆得到的那一份。
        #expect(ended == ["i1"])
    }

    @Test("兩份都沒有 token 時保留 instanceId 較小的那份")
    func duplicateWithoutTokenKeepsLowestId() {
        let a = Self.facts(
            instanceId: "i1",
            activityId: "inClass-A",
            countdownTarget: Self.now.addingTimeInterval(600)
        )
        let b = Self.facts(
            instanceId: "i2",
            activityId: "inClass-A",
            countdownTarget: Self.now.addingTimeInterval(600)
        )

        // 同上：instanceId 較小的 i1 放在後面。
        let ended = LiveActivityCoordinator.duplicateInstanceIdsToEnd([b, a])

        #expect(ended == ["i2"])
    }

    @Test("非 live 的副本不參與重複判定")
    func nonLiveCopiesAreIgnored() {
        let live = Self.facts(
            instanceId: "i1",
            activityId: "inClass-A",
            countdownTarget: Self.now.addingTimeInterval(600)
        )
        let dismissed = Self.facts(
            instanceId: "i2",
            activityId: "inClass-A",
            countdownTarget: Self.now.addingTimeInterval(600),
            isLive: false
        )

        let ended = LiveActivityCoordinator.duplicateInstanceIdsToEnd(
            [live, dismissed]
        )

        #expect(ended.isEmpty)
    }

    @Test("不同 activityId 不算重複")
    func differentActivityIdsAreNotDuplicates() {
        let a = Self.facts(
            instanceId: "i1",
            activityId: "inClass-A",
            countdownTarget: Self.now.addingTimeInterval(600)
        )
        let b = Self.facts(
            instanceId: "i2",
            activityId: "classPreparing-B",
            countdownTarget: Self.now.addingTimeInterval(7200)
        )

        let ended = LiveActivityCoordinator.duplicateInstanceIdsToEnd([a, b])

        #expect(ended.isEmpty)
    }

    // MARK: - 即時動態不可用

    @Test("即時動態不可用時全部結束，包括伺服器預排、倒數還沒到的活動")
    func unavailableEndsEveryActivity() {
        // 同步課程資訊關閉後，伺服器仍照先前上傳的排程，用 push-to-start
        // 啟動了 B 課的 classPreparing（2 小時後開始）；A 課的 inClass 還有
        // 30 分鐘；另有一個沒有倒數目標的。可用時三者都不該結束——這正是
        // `futurePrelaunchedActivitiesSurvive` 釘住的——不可用時則全部結束。
        let prelaunched = Self.facts(
            instanceId: "i1",
            activityId: "classPreparing-B",
            countdownTarget: Self.now.addingTimeInterval(2 * 3600),
            hasPushToken: true
        )
        let running = Self.facts(
            instanceId: "i2",
            activityId: "inClass-A",
            countdownTarget: Self.now.addingTimeInterval(30 * 60)
        )
        let untimed = Self.facts(
            instanceId: "i3",
            activityId: "assignmentUrgent-C",
            countdownTarget: nil
        )
        let all = [prelaunched, running, untimed]

        #expect(LiveActivityCoordinator.instanceIdsToEnd(all, now: Self.now, isAvailable: true).isEmpty)
        #expect(
            Set(LiveActivityCoordinator.instanceIdsToEnd(all, now: Self.now, isAvailable: false))
                == ["i1", "i2", "i3"]
        )
    }
}
