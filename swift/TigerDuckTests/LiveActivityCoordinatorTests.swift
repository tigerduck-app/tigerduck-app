import Foundation
import Testing
@testable import TigerDuck

/// Pins the coexistence invariant: several Live Activities can run at once, and
/// none is ended only because it is not the current resolved target. If these
/// tests start failing, read that rule in swift/TigerDuck/LiveActivity/AGENTS.md
/// before deciding whether to change the code or the tests.
@MainActor
struct LiveActivityCoordinatorTests {

    private static let now = Date(timeIntervalSince1970: 1_757_500_000)

    private static func facts(
        instanceId: String,
        activityId: String,
        countdownTarget: Date?,
        scenario: LiveActivityScenarioKind = .inClass,
        hasPushToken: Bool = false,
        isLive: Bool = true
    ) -> LiveActivityCoordinator.RunningActivityFacts {
        .init(
            instanceId: instanceId,
            activityId: activityId,
            scenario: scenario,
            countdownTarget: countdownTarget,
            hasPushToken: hasPushToken,
            isLive: isLive
        )
    }

    // MARK: - Expiry check

    @Test("伺服器預排的未來時段活動不會因為『不是當下目標』而被結束")
    func futurePrelaunchedActivitiesSurvive() {
        // Class A is in progress (ends in 30 minutes) and class B's classPreparing was
        // pre-started by push-to-start (starts in 2 hours). The resolver returns only
        // one of them at a time, and the other must not be ended for that.
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

    // MARK: - Duplicate copies

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

        // The copy to keep comes last, so an "always keep the first" implementation fails.
        let ended = LiveActivityCoordinator.duplicateInstanceIdsToEnd(
            [withoutToken, withToken]
        )

        // i2 wins despite i1's smaller instanceId, because it has the push token: it is
        // the copy the server can reach.
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

        // As above, i1, with the smaller instanceId, comes last.
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

    // MARK: - Live Activity unavailable

    @Test("即時動態不可用時全部結束，包括伺服器預排、倒數還沒到的活動")
    func unavailableEndsEveryActivity() {
        // With course sync off, the server still push-starts B's classPreparing (in 2 h)
        // from the uploaded schedule; A's inClass has 30 min left; one has no countdown.
        // None ends while available (`futurePrelaunchedActivitiesSurvive`); all end otherwise.
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

    // MARK: - Days without classes

    @Test("不上課的日子，課堂類活動會被結束，作業類留下")
    func quietDayEndsClassActivitiesOnly() {
        // The server still starts pre-class and in-class activities on a day without
        // classes, such as a typhoon day announced after the push. The same day has an
        // assignment due soon, and a class activity with no countdown, so no known day.
        let preparing = Self.facts(
            instanceId: "i1",
            activityId: "classPreparing-B",
            countdownTarget: Self.now.addingTimeInterval(2 * 3600),
            scenario: .classPreparing
        )
        let inClass = Self.facts(
            instanceId: "i2",
            activityId: "inClass-A",
            countdownTarget: Self.now.addingTimeInterval(30 * 60),
            scenario: .inClass
        )
        let assignment = Self.facts(
            instanceId: "i3",
            activityId: "assignmentUrgent-C",
            countdownTarget: Self.now.addingTimeInterval(3600),
            scenario: .assignmentUrgent
        )
        let untimed = Self.facts(
            instanceId: "i4",
            activityId: "inClass-D",
            countdownTarget: nil,
            scenario: .inClass
        )
        let all = [preparing, inClass, assignment, untimed]

        #expect(LiveActivityCoordinator.instanceIdsToEnd(all, now: Self.now, isAvailable: true).isEmpty)
        #expect(
            Set(LiveActivityCoordinator.instanceIdsToEnd(
                all, now: Self.now, isAvailable: true, isQuietDay: { _ in true }
            )) == ["i1", "i2"]
        )
    }

    // MARK: - Handling one activity (shared by prune and newly appearing activities)

    @Test("新出現的不上課日子課堂活動會被結束，不會留下來註冊 token")
    func quietDayClassIsEndedNotKept() {
        // Prune and the observer loop both act only on `endReason`: an activity with a
        // reason is ended, and only one without registers its update token. So a class
        // on a day without classes gets a reason and never reaches registration.
        let holidayEnds = Self.now.addingTimeInterval(12 * 3600)
        func reason(_ fact: LiveActivityCoordinator.RunningActivityFacts) -> LiveActivityCoordinator.EndReason? {
            LiveActivityCoordinator.endReason(
                for: fact, now: Self.now, isAvailable: true, isQuietDay: { $0 < holidayEnds }
            )
        }

        let quietClass = Self.facts(
            instanceId: "i1",
            activityId: "inClass-A",
            countdownTarget: Self.now.addingTimeInterval(30 * 60),
            scenario: .inClass
        )
        let quietAssignment = Self.facts(
            instanceId: "i2",
            activityId: "assignmentUrgent-B",
            countdownTarget: Self.now.addingTimeInterval(3600),
            scenario: .assignmentUrgent
        )
        let schoolDayClass = Self.facts(
            instanceId: "i3",
            activityId: "classPreparing-C",
            countdownTarget: Self.now.addingTimeInterval(24 * 3600),
            scenario: .classPreparing
        )

        #expect(reason(quietClass) == .quietDay)
        #expect(reason(quietAssignment) == nil)
        #expect(reason(schoolDayClass) == nil)
    }

    @Test("理由的先後：不可用、倒數已過、不上課")
    func endReasonPrecedence() {
        let expiredClass = Self.facts(
            instanceId: "i1",
            activityId: "inClass-A",
            countdownTarget: Self.now.addingTimeInterval(-60),
            scenario: .inClass
        )
        let reason = { (available: Bool) in
            LiveActivityCoordinator.endReason(
                for: expiredClass, now: Self.now, isAvailable: available, isQuietDay: { _ in true }
            )
        }

        #expect(reason(false) == .unavailable)
        #expect(reason(true) == .expired)
    }

    // MARK: - Final check before apply starts or updates

    private static func snapshot(
        _ scenario: LiveActivityScenarioKind,
        countdownTarget: Date?
    ) -> LiveActivitySnapshot {
        LiveActivitySnapshot(
            scenario: scenario,
            title: "Test",
            subtitle: "10:20 - 12:10",
            locationText: nil,
            instructor: nil,
            countdownTarget: countdownTarget,
            progressStart: nil,
            accentHex: 0,
            deepLink: nil,
            sourceId: "TEST100_20260925_3"
        )
    }

    @Test("prune 等待期間變成不上課的日子，apply 不會再啟動那堂課")
    func quietDayChangeStopsTheStart() {
        // apply prunes before it starts, prune awaits, and the snapshot was resolved
        // before that. If "Still have class?" is turned off or the academic calendar
        // gains a holiday meanwhile, the start has to check again.
        let target = Self.now.addingTimeInterval(30 * 60)
        let quiet: (Date) -> Bool = { _ in true }
        let schoolDay: (Date) -> Bool = { _ in false }
        func canStart(
            _ scenario: LiveActivityScenarioKind,
            available: Bool = true,
            isQuietDay: (Date) -> Bool
        ) -> Bool {
            LiveActivityCoordinator.canStart(
                Self.snapshot(scenario, countdownTarget: target),
                isAvailable: available,
                isQuietDay: isQuietDay
            )
        }

        #expect(!canStart(.inClass, isQuietDay: quiet))
        #expect(!canStart(.classPreparing, isQuietDay: quiet))
        #expect(canStart(.assignmentUrgent, isQuietDay: quiet))
        #expect(canStart(.inClass, isQuietDay: schoolDay))
        #expect(!canStart(.assignmentUrgent, available: false, isQuietDay: schoolDay))
    }

    @Test("判斷的是課堂自己的那一天")
    func quietDayIsJudgedOnTheClassesOwnDay() {
        // One class falls on the holiday and the other on a school day; only the first ends.
        let onHoliday = Self.facts(
            instanceId: "i1",
            activityId: "inClass-A",
            countdownTarget: Self.now.addingTimeInterval(30 * 60),
            scenario: .inClass
        )
        let onSchoolDay = Self.facts(
            instanceId: "i2",
            activityId: "classPreparing-B",
            countdownTarget: Self.now.addingTimeInterval(24 * 3600),
            scenario: .classPreparing
        )
        let holidayEnds = Self.now.addingTimeInterval(12 * 3600)

        #expect(
            LiveActivityCoordinator.instanceIdsToEnd(
                [onHoliday, onSchoolDay],
                now: Self.now,
                isAvailable: true,
                isQuietDay: { $0 < holidayEnds }
            ) == ["i1"]
        )
    }
}
