import Defaults
import Foundation
import SwiftData
import SwiftUI
import TigerDuckCore

@Model
final class SDCourse: Identifiable {
    @Attribute(.unique) var courseNo: String
    var courseName: String
    var instructor: String
    /// NTUST issues half credits, so this is fractional. See `creditsText`.
    var credits: Double
    var classroom: String
    var enrolledCount: Int
    var maxCount: Int

    @Transient var customName: String? = nil

    var displayName: String { customName ?? courseName }

    var scheduleJSON: String {
        didSet { _cachedSchedule = nil }
    }

    var classroomMapJSON: String = "{}" {
        didSet { _cachedClassroomMap = nil }
    }

    var moodleIdNumber: String?

    var dimension: String = ""

    var allYear: String = ""

    var requireOption: String = ""

    var isRequired: Bool { requireOption.uppercased() == "R" }

    var semester: String = ""

    var skippedDatesJSON: String = "[]"

    @Transient private var _cachedSchedule: [Int: [String]]?
    @Transient private var _cachedClassroomMap: [String: String]?

    var id: String { courseNo }

    init(
        courseNo: String,
        courseName: String,
        instructor: String = "",
        credits: Double = 0,
        classroom: String = "",
        enrolledCount: Int = 0,
        maxCount: Int = 0,
        schedule: [Int: [String]] = [:],
        moodleIdNumber: String? = nil,
        semester: String = "",
        classroomMap: [String: String] = [:],
        dimension: String = "",
        allYear: String = "",
        requireOption: String = ""
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
        self.semester = semester
        self.classroomMapJSON = (try? JSONEncoder().encode(classroomMap))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        self.dimension = dimension
        self.allYear = allYear
        self.requireOption = requireOption
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

    var classroomMap: [String: String] {
        if let cached = _cachedClassroomMap { return cached }
        guard let data = classroomMapJSON.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            _cachedClassroomMap = [:]
            return [:]
        }
        _cachedClassroomMap = dict
        return dict
    }

    /// Use this instead of writing ``classroomMapJSON`` directly: SwiftData's
    /// ``@Model`` macro rewrites stored-property accessors, so the ``didSet``
    /// that should reset ``_cachedClassroomMap`` does not fire reliably for
    /// in-memory mutations and stale reads leak through ``classroom(for:)``.
    func setClassroomMap(_ map: [String: String]) {
        if let data = try? JSONEncoder().encode(map),
           let str = String(data: data, encoding: .utf8) {
            classroomMapJSON = str
        }
        _cachedClassroomMap = map
    }

    /// Use this instead of assigning ``scheduleJSON`` directly: SwiftData's
    /// ``@Model`` macro rewrites stored-property accessors, so the
    /// ``didSet`` that should reset ``_cachedSchedule`` does not fire
    /// reliably for in-memory mutations and stale reads leak through.
    func setSchedule(_ schedule: [Int: [String]]) {
        let stringKeyDict = Dictionary(uniqueKeysWithValues: schedule.map { ("\($0.key)", $0.value) })
        if let data = try? JSONEncoder().encode(stringKeyDict),
           let str = String(data: data, encoding: .utf8) {
            scheduleJSON = str
        }
        _cachedSchedule = schedule
    }

    func classroom(for weekday: Int) -> String {
        let map = classroomMap
        guard !map.isEmpty else { return Self.dedup(classroom) }

        guard let periods = schedule[weekday] else { return Self.dedup(classroom) }

        var seen = Set<String>()
        var rooms: [String] = []
        for period in periods.sortedByPeriodOrder() {
            let key = "\(weekday)-\(period)"
            if let raw = map[key] {
                for part in Self.splitRoom(raw) where !seen.contains(part) {
                    seen.insert(part)
                    rooms.append(part)
                }
            }
        }
        return rooms.isEmpty ? Self.dedup(classroom) : rooms.joined(separator: ", ")
    }

    func classroom(weekday: Int, period: String) -> String {
        classroomMap["\(weekday)-\(period)"] ?? ""
    }

    func classroom(weekday: Int, periods: [String]) -> String {
        CourseBlockRoom.room(
            weekday: weekday, periods: periods, map: classroomMap, fallback: Self.dedup(classroom)
        )
    }

    static func splitRoom(_ raw: String) -> [String] {
        CourseBlockRoom.split(raw)
    }

    static func dedup(_ raw: String) -> String {
        var seen = Set<String>()
        var result: [String] = []
        for part in splitRoom(raw) where !seen.contains(part) {
            seen.insert(part)
            result.append(part)
        }
        return result.isEmpty ? raw : result.joined(separator: ", ")
    }

    var color: Color {
        TigerDuckTheme.courseColor(for: courseNo)
    }

    static func courseNoFromMoodleId(_ moodleId: String) -> String {
        guard AcademicTerm.codePrefix(ofMoodleId: moodleId) != nil else { return moodleId }
        return String(moodleId.dropFirst(4))
    }

    /// A Moodle `idnumber` with its term prefix normalised, so an id spelled
    /// by one system is found under a key written by the other:
    /// `"114hGD3115301"` and `"114HGD3115301"` both become the latter. An id
    static func normalizedMoodleId(_ moodleId: String) -> String {
        guard let prefix = AcademicTerm.codePrefix(ofMoodleId: moodleId) else { return moodleId }
        return prefix + moodleId.dropFirst(4)
    }

    func timeRange(for weekday: Int) -> String? {
        guard let periods = schedule[weekday], !periods.isEmpty else { return nil }
        return Self.timeRange(periods: periods)
    }

    static func timeRange(periods: [String]) -> String? {
        let sorted = periods.sortedByPeriodOrder()
        guard let first = sorted.first,
              let last = sorted.last,
              let firstTime = AppConstants.PeriodTimes.mapping[first],
              let lastTime = AppConstants.PeriodTimes.mapping[last] else { return nil }
        return "\(firstTime.start) - \(lastTime.end)"
    }

    func block(
        weekday: Int, at period: String, in order: [String] = AppConstants.Periods.chronologicalOrder
    ) -> [String]? {
        let own = Set(schedule[weekday] ?? [])
        var runs: [[String]] = []
        for (index, row) in order.enumerated() where own.contains(row) {
            if index > 0, own.contains(order[index - 1]), !runs.isEmpty {
                runs[runs.count - 1].append(row)
            } else {
                runs.append([row])
            }
        }
        let start = order.firstIndex(of: period) ?? 0
        return runs.first { $0.contains(period) }
            ?? runs.first { (order.firstIndex(of: $0[0]) ?? 0) > start }
    }
}

extension Array where Element == SDCourse {
    func coursesForToday() -> [SDCourse] {
        let today = AppClock.now().scheduleWeekday
        return filter { $0.schedule[today] != nil }
    }
}

extension SDCourse {
    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TaipeiTime.timeZone
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
        NotificationCenter.default.post(name: AppConstants.courseSkipStateDidChange, object: nil)
    }
}

extension SDCourse {
    var moodleDeepLink: URL? {
        guard let idnumber = moodleIdNumber, !idnumber.isEmpty,
              let numericId = DataCache.shared.lookupMoodleCourseId(idnumber: idnumber) else {
            return nil
        }

        return AppConstants.moodleDeepLink(redirectingTo: "/course/view.php?id=\(numericId)")
    }

    /// HTTPS equivalent of ``moodleDeepLink``. No Moodle Mac app exists, so
    /// the deep link's `moodlemobile://` scheme resolves to an unhandled-URL
    /// error there; macOS callers open this directly in the default browser.
    var moodleWebURL: URL? {
        guard let idnumber = moodleIdNumber, !idnumber.isEmpty,
              let numericId = DataCache.shared.lookupMoodleCourseId(idnumber: idnumber) else {
            return nil
        }
        let host = AppConstants.moodleBaseURL.host ?? "moodle2.ntust.edu.tw"
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/course/view.php"
        components.queryItems = [URLQueryItem(name: "id", value: String(numericId))]
        return components.url
    }

    var moodleOpenURL: URL? {
        #if os(macOS)
        switch Defaults[.macMoodleOpenTarget] {
        case .app: return moodleDeepLink
        case .browser: return moodleWebURL
        }
        #else
        return moodleDeepLink
        #endif
    }
}
