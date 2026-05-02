#if DEBUG
import Foundation

enum MockData {
    private static func daysFromNow(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
    }

    private static func todayAt(hour: Int, minute: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }

    static let courses: [SDCourse] = [
        SDCourse(
            courseNo: "EC1013701",
            courseName: "網際網路概論",
            instructor: "王大明",
            credits: 3,
            classroom: "RB-504",
            enrolledCount: 45,
            maxCount: 60,
            schedule: [1: ["3", "4"], 3: ["6", "7"]],
            moodleIdNumber: "1142EC1013701"
        ),
        SDCourse(
            courseNo: "CS2023301",
            courseName: "計算機組織",
            instructor: "李小華",
            credits: 3,
            classroom: "TR-313",
            enrolledCount: 50,
            maxCount: 55,
            schedule: [2: ["6", "7"], 4: ["6", "7"]],
            moodleIdNumber: "1142CS2023301"
        ),
        SDCourse(
            courseNo: "CS3034501",
            courseName: "人工智慧導論",
            instructor: "張教授",
            credits: 3,
            classroom: "RB-201",
            enrolledCount: 40,
            maxCount: 50,
            schedule: [1: ["6", "7", "8"]],
            moodleIdNumber: "1142CS3034501"
        ),
        SDCourse(
            courseNo: "MA1012001",
            courseName: "線性代數",
            instructor: "陳教授",
            credits: 3,
            classroom: "AU-101",
            enrolledCount: 55,
            maxCount: 60,
            schedule: [3: ["1", "2"], 5: ["1", "2"]],
            moodleIdNumber: "1142MA1012001"
        ),
        SDCourse(
            courseNo: "EE2045601",
            courseName: "電子學實驗",
            instructor: "林教授",
            credits: 1,
            classroom: "EE-302",
            enrolledCount: 30,
            maxCount: 30,
            schedule: [5: ["6", "7", "8"]],
            moodleIdNumber: "1142EE2045601"
        ),
        SDCourse(
            courseNo: "TEST12345",
            courseName: "測試的課程",
            instructor: "黃教授",
            credits: 1,
            classroom: "EE-302",
            enrolledCount: 30,
            maxCount: 30,
            schedule: [7: ["1", "2", "3"]],
            moodleIdNumber: "1142TEST12345"
        ),
    ]

    static let assignments: [SDAssignment] = [
        SDAssignment(
            assignmentId: "324494",
            courseNo: "CS3034501",
            courseName: "人工智慧導論",
            title: "HW3 搜尋演算法",
            dueDate: daysFromNow(3)
        ),
        SDAssignment(
            assignmentId: "322841",
            courseNo: "CS2023301",
            courseName: "計算機組織",
            title: "Project01 MIPS Pipeline",
            dueDate: daysFromNow(4)
        ),
        SDAssignment(
            assignmentId: "325100",
            courseNo: "EC1013701",
            courseName: "網際網路概論",
            title: "Lab5 TCP Socket",
            dueDate: daysFromNow(7)
        ),
    ]

    static let announcements: [SDAnnouncement] = [
        SDAnnouncement(
            announcementId: "n1",
            title: "113-2學期獎學金申請公告",
            summary: "各類獎學金即日起至4月30日止受理申請，請同學把握時間。",
            department: "學務處",
            publishDate: daysFromNow(-1),
            detailUrl: "https://lc.ntust.edu.tw/p/406-1070-143898,r1828.php"
        ),
        SDAnnouncement(
            announcementId: "n2",
            title: "選課異動通知",
            summary: "第二階段選課結果已公布，請同學至校務系統確認。",
            department: "教務處",
            publishDate: daysFromNow(-2),
            detailUrl: "https://lc.ntust.edu.tw/p/406-1070-143800,r1828.php"
        ),
        SDAnnouncement(
            announcementId: "n3",
            title: "圖書館暑假開放時間調整",
            summary: "暑假期間圖書館開放時間調整為 09:00-17:00。",
            department: "圖書館",
            publishDate: daysFromNow(-3),
            detailUrl: "https://lc.ntust.edu.tw/p/406-1070-143700,r1828.php"
        ),
        SDAnnouncement(
            announcementId: "n4",
            title: "校園防疫措施更新",
            summary: "依最新防疫指引，進入室內空間建議配戴口罩。",
            department: "總務處",
            publishDate: daysFromNow(-5),
            detailUrl: "https://lc.ntust.edu.tw/p/406-1070-143600,r1828.php"
        ),
        SDAnnouncement(
            announcementId: "n5",
            title: "國際交流獎學金計畫",
            summary: "113-2學期國際交流獎學金即日起開放申請，名額有限。",
            department: "國際處",
            publishDate: daysFromNow(-6),
            detailUrl: "https://lc.ntust.edu.tw/p/406-1070-143500,r1828.php"
        ),
    ]

    static let calendarEvents: [SDCalendarEvent] = [
        SDCalendarEvent(
            eventId: "e1",
            title: "網際網路概論",
            date: todayAt(hour: 10, minute: 10),
            source: .moodle
        ),
        SDCalendarEvent(
            eventId: "e2",
            title: "校務會議",
            date: todayAt(hour: 12, minute: 0),
            source: .school
        ),
        SDCalendarEvent(
            eventId: "e3",
            title: "期中考",
            date: todayAt(hour: 23, minute: 59),
            source: .exam
        ),
        SDCalendarEvent(
            eventId: "e4",
            title: "HW3 截止",
            date: daysFromNow(3),
            source: .moodle
        ),
        SDCalendarEvent(
            eventId: "e5",
            title: "畢業典禮",
            date: daysFromNow(10),
            source: .school
        ),
    ]
}
#endif
