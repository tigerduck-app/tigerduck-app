import Foundation
import SwiftData
import SwiftUI

@Model
final class SDCourse: Identifiable {
    @Attribute(.unique) var courseNo: String
    var courseName: String
    var instructor: String
    var credits: Int
    var classroom: String
    var enrolledCount: Int
    var maxCount: Int

    /// Schedule stored as JSON: {"1":["3","4"],"3":["6","7"]}
    /// Keys = weekday (1=Mon..7=Sun), Values = period IDs
    var scheduleJSON: String {
        didSet { _cachedSchedule = nil }
    }

    /// Moodle course ID number (e.g. "1142EC1013701")
    var moodleIdNumber: String?

    var skippedDatesJSON: String = "[]"

    @Transient private var _cachedSchedule: [Int: [String]]?

    var id: String { courseNo }

    init(
        courseNo: String,
        courseName: String,
        instructor: String = "",
        credits: Int = 0,
        classroom: String = "",
        enrolledCount: Int = 0,
        maxCount: Int = 0,
        schedule: [Int: [String]] = [:],
        moodleIdNumber: String? = nil
    ) {
        self.courseNo = courseNo
        self.courseName = courseName
        self.instructor = instructor
        self.credits = credits
        self.classroom = classroom
        self.enrolledCount = enrolledCount
        self.maxCount = maxCount
        let stringKeyDict = Dictionary(uniqueKeysWithValues: schedule.map { ("\($0.key)", $0.value) })
        self.scheduleJSON = (try? JSONEncoder().encode(stringKeyDict))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        self.moodleIdNumber = moodleIdNumber
    }

    var schedule: [Int: [String]] {
        if let cached = _cachedSchedule { return cached }
        guard let data = scheduleJSON.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            _cachedSchedule = [:]
            return [:]
        }
        let decoded = Dictionary(uniqueKeysWithValues: dict.compactMap { key, value -> (Int, [String])? in
            guard let intKey = Int(key) else { return nil }
            return (intKey, value)
        })
        _cachedSchedule = decoded
        return decoded
    }

    var color: Color {
        TigerDuckTheme.courseColor(for: courseNo)
    }

    static func courseNoFromMoodleId(_ moodleId: String) -> String {
        if moodleId.count > 4 {
            return String(moodleId.dropFirst(4))
        }
        return moodleId
    }

    /// Returns the formatted time range string for this course on the given weekday, e.g. "08:10 - 12:10"
    func timeRange(for weekday: Int) -> String? {
        guard let periods = schedule[weekday], !periods.isEmpty else { return nil }
        let sorted = periods.sortedByPeriodOrder()
        guard let first = sorted.first,
              let last = sorted.last,
              let firstTime = AppConstants.PeriodTimes.mapping[first],
              let lastTime = AppConstants.PeriodTimes.mapping[last] else { return nil }
        return "\(firstTime.start) - \(lastTime.end)"
    }
}

extension Array where Element == SDCourse {
    /// Courses that have a schedule entry for today's weekday.
    func coursesForToday() -> [SDCourse] {
        let today = Date().scheduleWeekday
        return filter { $0.schedule[today] != nil }
    }
}

extension SDCourse {
    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var skippedDates: [String] {
        get {
            guard let data = skippedDatesJSON.data(using: .utf8),
                  let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return arr
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let str = String(data: data, encoding: .utf8) {
                skippedDatesJSON = str
            }
        }
    }

    func isSkipped(on date: Date) -> Bool {
        let key = Self.isoFormatter.string(from: date)
        return skippedDates.contains(key)
    }

    func toggleSkip(on date: Date) {
        let key = Self.isoFormatter.string(from: date)
        var dates = skippedDates
        if let index = dates.firstIndex(of: key) {
            dates.remove(at: index)
        } else {
            dates.append(key)
        }
        skippedDates = dates
    }
}
