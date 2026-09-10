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
}
