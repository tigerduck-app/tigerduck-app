import Defaults
import Foundation
import TigerDuckCore

/// The dates a course is skipped on, stored in `SDCourse.skippedDatesJSON` as a JSON array of
/// `yyyy-MM-dd` days in Taipei time.
enum CourseSkipDates {
    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TaipeiTime.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func key(for date: Date) -> String {
        isoFormatter.string(from: date)
    }

    static func decode(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let dates = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return dates
    }

    /// Nil when the dates do not encode, which leaves the stored ones as they were.
    static func encode(_ dates: [String]) -> String? {
        guard let data = try? JSONEncoder().encode(dates) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func toggling(_ key: String, in dates: [String]) -> [String] {
        var dates = dates
        if let index = dates.firstIndex(of: key) {
            dates.remove(at: index)
        } else {
            dates.append(key)
        }
        return dates
    }
}

/// A Moodle course page by the course's Moodle `idnumber`, once the course list mapped it to
/// Moodle's numeric id.
enum MoodleCourseLink {
    static func deepLink(idnumber: String?) -> URL? {
        numericId(idnumber).flatMap { AppConstants.moodleDeepLink(redirectingTo: "/course/view.php?id=\($0)") }
    }

    /// No Moodle Mac app exists, so the deep link's `moodlemobile://` scheme fails to open there;
    /// macOS opens this in the default browser.
    static func webURL(idnumber: String?) -> URL? {
        guard let numericId = numericId(idnumber) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = AppConstants.moodleBaseURL.host ?? "moodle2.ntust.edu.tw"
        components.path = "/course/view.php"
        components.queryItems = [URLQueryItem(name: "id", value: String(numericId))]
        return components.url
    }

    static func openURL(idnumber: String?) -> URL? {
        #if os(macOS)
        switch Defaults[.macMoodleOpenTarget] {
        case .app: return deepLink(idnumber: idnumber)
        case .browser: return webURL(idnumber: idnumber)
        }
        #else
        return deepLink(idnumber: idnumber)
        #endif
    }

    private static func numericId(_ idnumber: String?) -> Int? {
        guard let idnumber, !idnumber.isEmpty else { return nil }
        return MoodleFiles.shared.lookupMoodleCourseId(idnumber: idnumber)
    }
}

enum CourseRoomList {
    static func rooms(of periods: [String]?, weekday: Int, map: [String: String], fallback: String) -> String {
        guard !map.isEmpty, let periods else { return fallback }
        var seen = Set<String>()
        var rooms: [String] = []
        for period in periods.sortedByPeriodOrder() {
            if let raw = map["\(weekday)-\(period)"] {
                for part in SDCourse.splitRoom(raw) where !seen.contains(part) {
                    seen.insert(part)
                    rooms.append(part)
                }
            }
        }
        return rooms.isEmpty ? fallback : rooms.joined(separator: ", ")
    }
}
