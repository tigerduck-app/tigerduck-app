import Foundation

enum MockData {
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
            dueDate: Calendar.current.date(byAdding: .day, value: 3, to: Date())!
        ),
        SDAssignment(
            assignmentId: "322841",
            courseNo: "CS2023301",
            courseName: "計算機組織",
            title: "Project01 MIPS Pipeline",
            dueDate: Calendar.current.date(byAdding: .day, value: 4, to: Date())!
        ),
        SDAssignment(
            assignmentId: "325100",
            courseNo: "EC1013701",
            courseName: "網際網路概論",
            title: "Lab5 TCP Socket",
            dueDate: Calendar.current.date(byAdding: .day, value: 7, to: Date())!
        ),
    ]

    static let announcements: [SDAnnouncement] = [
        SDAnnouncement(
            announcementId: "n1",
            title: "113-2學期獎學金申請公告",
            summary: "各類獎學金即日起至4月30日止受理申請，請同學把握時間。",
            department: "學務處",
            publishDate: Calendar.current.date(byAdding: .day, value: -1, to: Date())!,
            detailUrl: "https://lc.ntust.edu.tw/p/406-1070-143898,r1828.php"
        ),
        SDAnnouncement(
            announcementId: "n2",
            title: "選課異動通知",
            summary: "第二階段選課結果已公布，請同學至校務系統確認。",
            department: "教務處",
            publishDate: Calendar.current.date(byAdding: .day, value: -2, to: Date())!,
            detailUrl: "https://lc.ntust.edu.tw/p/406-1070-143800,r1828.php"
        ),
        SDAnnouncement(
            announcementId: "n3",
            title: "圖書館暑假開放時間調整",
            summary: "暑假期間圖書館開放時間調整為 09:00-17:00。",
            department: "圖書館",
            publishDate: Calendar.current.date(byAdding: .day, value: -3, to: Date())!,
            detailUrl: "https://lc.ntust.edu.tw/p/406-1070-143700,r1828.php"
        ),
        SDAnnouncement(
            announcementId: "n4",
            title: "校園防疫措施更新",
            summary: "依最新防疫指引，進入室內空間建議配戴口罩。",
            department: "總務處",
            publishDate: Calendar.current.date(byAdding: .day, value: -5, to: Date())!,
            detailUrl: "https://lc.ntust.edu.tw/p/406-1070-143600,r1828.php"
        ),
        SDAnnouncement(
            announcementId: "n5",
            title: "國際交流獎學金計畫",
            summary: "113-2學期國際交流獎學金即日起開放申請，名額有限。",
            department: "國際處",
            publishDate: Calendar.current.date(byAdding: .day, value: -6, to: Date())!,
            detailUrl: "https://lc.ntust.edu.tw/p/406-1070-143500,r1828.php"
        ),
    ]

    static let calendarEvents: [SDCalendarEvent] = [
        SDCalendarEvent(
            eventId: "e1",
            title: "網際網路概論",
            date: Calendar.current.date(bySettingHour: 10, minute: 10, second: 0, of: Date())!,
            source: .moodle
        ),
        SDCalendarEvent(
            eventId: "e2",
            title: "校務會議",
            date: Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!,
            source: .school
        ),
        SDCalendarEvent(
            eventId: "e3",
            title: "期中考",
            date: Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: Date())!,
            source: .exam
        ),
        SDCalendarEvent(
            eventId: "e4",
            title: "HW3 截止",
            date: Calendar.current.date(byAdding: .day, value: 3, to: Date())!,
            source: .moodle
        ),
        SDCalendarEvent(
            eventId: "e5",
            title: "畢業典禮",
            date: Calendar.current.date(byAdding: .day, value: 10, to: Date())!,
            source: .school
        ),
    ]
}
