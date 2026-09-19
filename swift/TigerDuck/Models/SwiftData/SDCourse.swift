import Defaults
import Foundation
import SwiftData
import SwiftUI

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

    /// User-supplied alias for `courseName`. Kept transient because the
    /// canonical store is `DataCache.loadCourseCustomNames()`; persisting it
    /// here would let SwiftData round-trip the override through cache rebuilds
    /// and bypass the rename mechanism (see `CanonicalCourseProvider.merge`).
    /// Read via `displayName`.
    @Transient var customName: String? = nil

    /// What to show to the user — custom name when set, otherwise the
    /// canonical API name. Use this anywhere a course label is rendered
    /// (UI / widget / Live Activity / notification body); keep
    /// `courseName` for matching, persistence, and search.
    var displayName: String { customName ?? courseName }

    /// Schedule stored as JSON: {"1":["3","4"],"3":["6","7"]}
    /// Keys = weekday (1=Mon..7=Sun), Values = period IDs
    var scheduleJSON: String {
        didSet { _cachedSchedule = nil }
    }

    /// Classroom per (weekday, period) as JSON: {"1-3":"TR-313","1-4":"TR-313","4-10":"TR-409"}
    /// Key format: "weekday-period"
    var classroomMapJSON: String = "{}" {
        didSet { _cachedClassroomMap = nil }
    }

    /// Moodle course ID number (e.g. "1142EC1013701")
    var moodleIdNumber: String?

    /// General-education dimension from QueryCourse (`Dimension`), e.g. "C".
    /// Empty for every course that carries none — which is most of them.
    var dimension: String = ""

    /// Term span from QueryCourse (`AllYear`): "F" = full academic year,
    /// "H" = a single semester. Empty when the portal reported neither,
    /// which is how a row cached before this field existed reads.
    var allYear: String = ""

    /// Semester code for which this course was enrolled (e.g. "1142").
    /// Empty string = unknown / pre-feature cache; treated as current semester.
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
        allYear: String = ""
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

    /// Parsed classroom map: "weekday-period" → classroom name
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

    /// Update the per-period classroom map and its JSON backing in one shot.
    /// Use this instead of writing ``classroomMapJSON`` directly: SwiftData's
    /// ``@Model`` macro rewrites stored-property accessors, so the ``didSet``
    /// that should reset ``_cachedClassroomMap`` does not fire reliably for
    /// in-memory mutations and stale reads leak through ``classroom(for:)``.
    func setClassroomMap(_ map: [String: String]) {
        if let data = try? JSONEncoder().encode(map),
           let str = String(data: data, encoding: .utf8) {
            classroomMapJSON = str
        }
        // On encode failure, keep the previously-persisted JSON rather
        // than overwriting with "{}" — same rationale as `setSchedule`:
        // SwiftData re-hydrating from "{}" would silently drop every
        // per-period classroom entry on next launch.
        _cachedClassroomMap = map
    }

    /// Update the per-weekday schedule map and its JSON backing in one shot.
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
        // On encode failure, deliberately keep the previously-persisted
        // `scheduleJSON` rather than overwriting with "{}". A stale-but-
        // non-empty schedule on next launch is far better than every
        // period silently disappearing because SwiftData re-hydrated
        // from "{}". The in-memory cache still reflects this call so
        // the current session sees the new value.
        _cachedSchedule = schedule
    }

    /// Returns the classroom(s) for a specific weekday, deduped.
    /// Falls back to the flat `classroom` string if no map data.
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

    /// The room recorded for exactly one `(weekday, period)` slot, or ""
    /// when the map holds none. Unlike ``classroom(for:)`` this never joins
    /// a day's rooms into a list, so a course that meets twice in one day
    /// in two different rooms still reports one room per block.
    func classroom(weekday: Int, period: String) -> String {
        classroomMap["\(weekday)-\(period)"] ?? ""
    }

    private static let roomSeparators = CharacterSet(charactersIn: "、，,")

    /// Split a classroom string by common separators, trim, drop empties.
    static func splitRoom(_ raw: String) -> [String] {
        raw.components(separatedBy: roomSeparators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Dedup a raw classroom string that may contain separator-joined duplicates.
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

    /// The 4-character term prefix of a Moodle `idnumber`, normalised, or
    /// `nil` when the id carries none.
    ///
    /// A regular term is four digits (`1151`). A summer term's fourth
    /// character is a letter — and the two systems disagree on its case:
    /// NTUST's own `api/semestersinfo` publishes `114H`, while Moodle's
    /// `idnumber` spells it `114h`. Every term check downstream is a string
    /// comparison against NTUST's spelling, so the prefix is upper-cased
    /// here, once, instead of at each comparison. Requiring all four digits
    /// is what used to drop summer courses on the floor: `courseNo` and
    /// `semester` both came back empty and the assignment pipeline filtered
    /// the course out three times over.
    static func semesterPrefix(ofMoodleId moodleId: String) -> String? {
        guard moodleId.count > 4 else { return nil }
        let prefix = moodleId.prefix(4)
        guard prefix.dropLast().allSatisfy(\.isNumber),
              let term = prefix.last,
              term.isNumber || term.isLetter else { return nil }
        return prefix.uppercased()
    }

    static func courseNoFromMoodleId(_ moodleId: String) -> String {
        guard semesterPrefix(ofMoodleId: moodleId) != nil else { return moodleId }
        return String(moodleId.dropFirst(4))
    }

    /// A Moodle `idnumber` with its term prefix normalised, so an id spelled
    /// by one system is found under a key written by the other:
    /// `"114hGD3115301"` and `"114HGD3115301"` both become the latter. An id
    /// with no term prefix is returned unchanged, and a regular all-digit
    /// term is already its own normal form.
    ///
    /// Used on both sides of the Moodle course-id map, which is the only
    /// thing standing between a course row and its "open in Moodle" button.
    static func normalizedMoodleId(_ moodleId: String) -> String {
        guard let prefix = semesterPrefix(ofMoodleId: moodleId) else { return moodleId }
        return prefix + moodleId.dropFirst(4)
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
        let today = AppClock.now().scheduleWeekday
        return filter { $0.schedule[today] != nil }
    }
}

extension SDCourse {
    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        // Pin to Taipei so a traveler marking "today" as skipped still
        // hits the same calendar day the widget/timeline derivation
        // computes — both sides must agree on what `yyyy-MM-dd` resolves
        // to or the skip silently misses.
        f.timeZone = AppConstants.taipeiTimeZone
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
        // Wake the LiveActivity refresh path so the lock-screen
        // activity reflects the toggle without waiting for the next
        // background sync tick. The resolver re-evaluates skip state
        // only on a new resolve; without this nudge a user marking
        // the in-progress class as skipped would still see it on the
        // lock screen until something else triggers a refresh.
        NotificationCenter.default.post(name: AppConstants.courseSkipStateDidChange, object: nil)
    }
}

extension SDCourse {
    /// Deep link into the Moodle Mobile app for this course. Mirrors
    /// ``SDAssignment/moodleDeepLink`` — same `moodlemobile://https://<host>?redirect=…`
    /// envelope pointing at `/course/view.php?id=<N>`. The numeric id is
    /// looked up from ``DataCache/lookupMoodleCourseId(idnumber:)``, which
    /// ``AppServiceBridge`` keeps fresh off the enrolled-courses fetch.
    ///
    /// Returns `nil` when either no idnumber is recorded for the course
    /// (e.g. user-added courses), or the id-map cache hasn't been populated
    /// yet (cold launch before first sync) — UI hides the button in both
    /// cases so the user never taps into an "app cannot open this URL" sheet.
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

    /// Platform-appropriate URL for "open in Moodle" actions. iOS uses the
    /// deep link so Moodle Mobile picks it up when installed; macOS reads
    /// the user's `macMoodleOpenTarget` preference — the iPad Moodle app
    /// installed via Mac App Store also registers `moodlemobile://`, so
    /// users who opted in get the deep link too. Default is `.browser`
    /// (HTTPS) since the iPad app isn't installed by default.
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
