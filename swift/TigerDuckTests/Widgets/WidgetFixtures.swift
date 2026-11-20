import Foundation
import TigerDuckCore
@testable import TigerDuck

enum WidgetFixtures {
    static let longName = "通識：科技、社會與永續發展導論與跨領域整合實作"
    static let longRoom = "IB-505／線上同步"

    static func wednesday(_ hour: Int, _ minute: Int) -> Date {
        TaipeiTime.calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: hour, minute: minute))!
    }

    static let autumn = QuietDayCalendar.Span(
        start: TaipeiTime.calendar.date(from: DateComponents(year: 2026, month: 9, day: 14))!,
        end: TaipeiTime.calendar.date(from: DateComponents(year: 2027, month: 1, day: 15))!
    )

    static func course(_ courseNo: String, _ name: String, _ room: String, _ schedule: [Int: [String]], _ color: UInt32) -> SnapshotCourse {
        SnapshotCourse(courseNo: courseNo, displayName: name, classroom: room, schedule: schedule, colorHex: color)
    }

    static func week(long: Bool = false) -> [SnapshotCourse] {
        [
            course("MA1001", "機率與統計", "TR-511", [1: ["1", "2"]], 0xDDA0DD),
            course("CS3001", "計算機網路概論", "IB-505", [1: ["6", "7"], 3: ["6", "7"]], 0xF39C12),
            course("MA2001", "工程數學", "EE-301", [2: ["3", "4"], 3: ["1", "2"]], 0x3498DB),
            course("FL1001", "專業英文", "RB-104", [2: ["8", "9"]], 0x45B7D1),
            course(
                "CS2001", long ? longName : "資料結構與演算法", long ? longRoom : "TR-412",
                [3: ["3", "4"], 4: ["3", "4"]], 0x4ECDC4
            ),
            course("PE1001", "體育－羽球", "GY-201", [3: ["8"]], 0xFF6B6B),
            course("GE1001", "通識：科技、社會與永續發展導論", "AU-105", [3: ["9"]], 0x9B59B6),
            course("MA1002", "線性代數", "RB-105", [4: ["1", "2"], 5: ["7", "8"]], 0x2ECC71),
            course("EE4001", "專題討論", "T4-501", [4: ["8", "9"]], 0xF7DC6F),
            course("EE3001", "微處理機實驗", "EE-705", [5: ["2", "3", "4"]], 0xE67E22),
        ]
    }

    static func snapshot(
        courses: [SnapshotCourse] = week(), isLoggedIn: Bool = true, term: QuietDayCalendar.Span? = autumn
    ) -> WidgetSnapshot {
        WidgetSnapshot(
            version: WidgetSnapshot.currentVersion,
            generatedAt: Date(timeIntervalSince1970: 0),
            isLoggedIn: isLoggedIn,
            accentColorHex: 0x007AFF,
            courses: courses,
            periodTimes: AppConstants.PeriodTimes.mapping.mapValues { PeriodTime(start: $0.start, end: $0.end) },
            periodOrder: AppConstants.Periods.chronologicalOrder,
            activeWeekdays: [1, 2, 3, 4, 5],
            activePeriodIds: AppConstants.Periods.defaultVisible,
            term: term
        )
    }
}
