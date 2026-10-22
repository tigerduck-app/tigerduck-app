import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct LiveActivityCoordinatorTests {

    private static let now = Date(timeIntervalSince1970: 1_757_500_000)

    private static func facts(
        instanceId: String,
        activityId: String,
        countdownTarget: Date?,
        scenario: LiveActivityScenarioKind = .inClass,
        sourceId: String = "TEST100_20260925_3",
        hasPushToken: Bool = false,
        isLive: Bool = true
    ) -> LiveActivityCoordinator.RunningActivityFacts {
        .init(
            instanceId: instanceId,
            activityId: activityId,
            sourceId: sourceId,
            scenario: scenario,
            countdownTarget: countdownTarget,
            hasPushToken: hasPushToken,
            isLive: isLive
        )
    }

    @Test("伺服器預排的未來時段活動不會因為『不是當下目標』而被結束")
    func futurePrelaunchedActivitiesSurvive() {
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

        let ended = LiveActivityCoordinator.duplicateInstanceIdsToEnd(
            [withoutToken, withToken]
        )

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

    @Test("即時動態不可用時全部結束，包括伺服器預排、倒數還沒到的活動")
    func unavailableEndsEveryActivity() {
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

    @Test("不上課的日子，課堂類活動會被結束，作業類留下")
    func quietDayEndsClassActivitiesOnly() {
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

    private static let cachedAssignments = [
        SDAssignment(
            assignmentId: "901", courseNo: "CS101", courseName: "Algorithms", title: "Lab 1",
            dueDate: now.addingTimeInterval(3600), isCompleted: true
        ),
        SDAssignment(
            assignmentId: "902", courseNo: "CS101", courseName: "Algorithms", title: "Lab 2",
            dueDate: now.addingTimeInterval(3600), isArchived: true
        ),
        SDAssignment(
            assignmentId: "903", courseNo: "CS101", courseName: "Algorithms", title: "Lab 3",
            dueDate: now.addingTimeInterval(3600), isLocallyCompleted: true
        ),
        SDAssignment(
            assignmentId: "904", courseNo: "CS101", courseName: "Algorithms", title: "Lab 4",
            dueDate: now.addingTimeInterval(3600)
        ),
    ]

    private static func isOutstanding(_ id: String) -> Bool? {
        LiveActivityScenarioResolver.isOutstanding(assignmentId: id, in: cachedAssignments)
    }

    private static func assignmentFacts(
        instanceId: String,
        assignmentId: String
    ) -> LiveActivityCoordinator.RunningActivityFacts {
        facts(
            instanceId: instanceId,
            activityId: "assignmentUrgent::\(assignmentId)",
            countdownTarget: now.addingTimeInterval(3600),
            scenario: .assignmentUrgent,
            sourceId: assignmentId
        )
    }

    @Test func doneAssignmentsEndTheirActivities() {
        let all = ["901", "902", "903", "904", "905"].enumerated().map { index, id in
            Self.assignmentFacts(instanceId: "i\(index + 1)", assignmentId: id)
        }

        #expect(LiveActivityCoordinator.instanceIdsToEnd(all, now: Self.now, isAvailable: true).isEmpty)
        #expect(
            Set(LiveActivityCoordinator.instanceIdsToEnd(
                all, now: Self.now, isAvailable: true, isAssignmentOutstanding: Self.isOutstanding
            )) == ["i1", "i2", "i3"]
        )
    }

    @Test func skippedClassesEndTheirActivities() {
        let preparing = Self.facts(
            instanceId: "i1",
            activityId: "classPreparing::TEST100_20260925_3",
            countdownTarget: Self.now.addingTimeInterval(2 * 3600),
            scenario: .classPreparing
        )
        let inClass = Self.facts(
            instanceId: "i2",
            activityId: "inClass::TEST200_20260925_6",
            countdownTarget: Self.now.addingTimeInterval(30 * 60),
            sourceId: "TEST200_20260925_6"
        )
        let assignment = Self.assignmentFacts(instanceId: "i3", assignmentId: "904")
        let all = [preparing, inClass, assignment]

        #expect(LiveActivityCoordinator.instanceIdsToEnd(all, now: Self.now, isAvailable: true).isEmpty)
        #expect(
            LiveActivityCoordinator.instanceIdsToEnd(
                all, now: Self.now, isAvailable: true, isSkipped: { $0 == "TEST100_20260925_3" }
            ) == ["i1"]
        )
        #expect(
            Set(LiveActivityCoordinator.instanceIdsToEnd(all, now: Self.now, isAvailable: true, isSkipped: { _ in true }))
                == ["i1", "i2"]
        )
    }

    @Test func skippedClassIsEndedNotKept() {
        let reason = LiveActivityCoordinator.endReason(
            for: Self.facts(
                instanceId: "i1",
                activityId: "classPreparing::TEST100_20260925_3",
                countdownTarget: Self.now.addingTimeInterval(3600),
                scenario: .classPreparing
            ),
            now: Self.now,
            isAvailable: true,
            isQuietDay: { _ in false },
            isAssignmentOutstanding: { _ in nil },
            isSkipped: { _ in true }
        )

        #expect(reason == .skippedClass)
    }

    @Test func skippedClassStopsTheStart() {
        func canStart(_ scenario: LiveActivityScenarioKind, sourceId: String, isSkipped: (String) -> Bool) -> Bool {
            LiveActivityCoordinator.canStart(
                Self.snapshot(scenario, countdownTarget: Self.now.addingTimeInterval(1800), sourceId: sourceId),
                isAvailable: true,
                isQuietDay: { _ in false },
                isAssignmentOutstanding: { _ in nil },
                isSkipped: isSkipped
            )
        }

        #expect(!canStart(.inClass, sourceId: "TEST100_20260925_3") { _ in true })
        #expect(!canStart(.classPreparing, sourceId: "TEST100_20260925_3") { _ in true })
        #expect(canStart(.inClass, sourceId: "TEST100_20260925_3") { _ in false })
        #expect(canStart(.assignmentUrgent, sourceId: "904") { _ in true })
    }

    @Test("新出現的不上課日子課堂活動會被結束，不會留下來註冊 token")
    func quietDayClassIsEndedNotKept() {
        let holidayEnds = Self.now.addingTimeInterval(12 * 3600)
        func reason(_ fact: LiveActivityCoordinator.RunningActivityFacts) -> LiveActivityCoordinator.EndReason? {
            LiveActivityCoordinator.endReason(
                for: fact,
                now: Self.now,
                isAvailable: true,
                isQuietDay: { $0 < holidayEnds },
                isAssignmentOutstanding: { _ in nil },
                isSkipped: { _ in false }
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

    @Test func doneAssignmentIsEndedNotKept() {
        func reason(_ fact: LiveActivityCoordinator.RunningActivityFacts) -> LiveActivityCoordinator.EndReason? {
            LiveActivityCoordinator.endReason(
                for: fact,
                now: Self.now,
                isAvailable: true,
                isQuietDay: { _ in false },
                isAssignmentOutstanding: { _ in false },
                isSkipped: { _ in false }
            )
        }
        let preparing = Self.facts(
            instanceId: "i2",
            activityId: "classPreparing-B",
            countdownTarget: Self.now.addingTimeInterval(3600),
            scenario: .classPreparing
        )

        #expect(reason(Self.assignmentFacts(instanceId: "i1", assignmentId: "901")) == .assignmentDone)
        #expect(reason(preparing) == nil)
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
                for: expiredClass,
                now: Self.now,
                isAvailable: available,
                isQuietDay: { _ in true },
                isAssignmentOutstanding: { _ in nil },
                isSkipped: { _ in true }
            )
        }

        #expect(reason(false) == .unavailable)
        #expect(reason(true) == .expired)
    }

    private static func snapshot(
        _ scenario: LiveActivityScenarioKind,
        countdownTarget: Date?,
        sourceId: String = "TEST100_20260925_3"
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
            sourceId: sourceId
        )
    }

    @Test("prune 等待期間變成不上課的日子，apply 不會再啟動那堂課")
    func quietDayChangeStopsTheStart() {
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
                isQuietDay: isQuietDay,
                isAssignmentOutstanding: { _ in nil },
                isSkipped: { _ in false }
            )
        }

        #expect(!canStart(.inClass, isQuietDay: quiet))
        #expect(!canStart(.classPreparing, isQuietDay: quiet))
        #expect(canStart(.assignmentUrgent, isQuietDay: quiet))
        #expect(canStart(.inClass, isQuietDay: schoolDay))
        #expect(!canStart(.assignmentUrgent, available: false, isQuietDay: schoolDay))
    }

    @Test func doneAssignmentStopsTheStart() {
        func canStart(_ assignmentId: String) -> Bool {
            LiveActivityCoordinator.canStart(
                Self.snapshot(
                    .assignmentUrgent,
                    countdownTarget: Self.now.addingTimeInterval(3600),
                    sourceId: assignmentId
                ),
                isAvailable: true,
                isQuietDay: { _ in false },
                isAssignmentOutstanding: Self.isOutstanding,
                isSkipped: { _ in false }
            )
        }

        #expect(!canStart("903"))
        #expect(canStart("904"))
        #expect(canStart("905"))
    }

    @Test("判斷的是課堂自己的那一天")
    func quietDayIsJudgedOnTheClassesOwnDay() {
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
