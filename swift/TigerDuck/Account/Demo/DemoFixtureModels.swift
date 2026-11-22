import Foundation
import TigerDuckCore

extension DemoFixture.Course {
    func course(in language: DemoLanguage, semester: String, onMoodle: Bool) -> SDCourse {
        let byWeekday = (schedule ?? [:]).compactMap { key, periods in Int(key).map { ($0, periods) } }
        return SDCourse(
            courseNo: courseNo, courseName: name.text(in: language), instructor: instructor?.text(in: language) ?? "",
            credits: credits ?? 0, classroom: classroom ?? "",
            schedule: Dictionary(byWeekday, uniquingKeysWith: { first, _ in first }),
            moodleIdNumber: onMoodle ? semester + courseNo : nil, semester: semester, classroomMap: classroomMap ?? [:]
        )
    }

    var pickedHex: UInt32? {
        guard let colorHex, colorHex.hasPrefix("#") else { return nil }
        return UInt32(colorHex.dropFirst(), radix: 16)
    }
}

extension DemoFixture.Assignment {
    func assignment(in language: DemoLanguage) -> SDAssignment? {
        guard let dueDate = DemoTime.date(due) else { return nil }
        return SDAssignment(
            assignmentId: id, courseNo: courseNo, courseName: courseName?.text(in: language) ?? "",
            title: title.text(in: language), dueDate: dueDate, isCompleted: completed ?? false
        )
    }
}

extension DemoFixture.CalendarEntry {
    func event(index: Int) -> SDCalendarEvent? {
        guard let date = DemoTime.date(self.date) else { return nil }
        return SDCalendarEvent(
            eventId: id ?? "demo-calendar-\(index)", title: title, date: date,
            source: source.flatMap(EventSource.init(rawValue:)) ?? .school
        )
    }
}

extension DemoFixture.CourseChange {
    func row(from today: Date) -> CourseChangesDTO.Row {
        let day = ClassTableViewModel.nextDate(onWeekday: weekday, from: today)
        return CourseChangesDTO.Row(
            id: id, course_no: courseNo, kind: kind, periods: periods, class_days: [TaipeiTime.dayKey(for: day)],
            room: room, start: start, end: end, note_zh: note?.text(in: .zh), note_en: note?.text(in: .en)
        )
    }
}

extension DemoFixture.Bulletin {
    func detail(index: Int) -> BulletinAPI.BulletinDetail {
        let id = self.id ?? index + 1
        return BulletinAPI.BulletinDetail(
            id: id, externalId: "demo-\(id)", title: title, titleClean: nil, canonicalOrg: org, contentTags: tags ?? [],
            importance: nil, summary: summary, sourceUrl: sourceUrl ?? "", postedAt: DemoTime.date(postedAt),
            isDeleted: false, bodyClean: nil, bodyMd: summary, rawPublisher: org
        )
    }
}
