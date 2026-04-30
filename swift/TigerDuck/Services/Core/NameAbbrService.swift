import Foundation
import Defaults

final class NameAbbrService: @unchecked Sendable {
    static let shared = NameAbbrService()

    private var courseAbbr: [String: String] = [:]
    private var classroomAbbr: [String: ClassroomAbbrEntry] = [:]
    private var abbrLoaded = false

    // In-memory map of courseNo → raw API course name.
    // Populated during AppServiceBridge.fetchCourses; cleared on language change.
    // Allows instant abbreviation toggle without a network round-trip.
    private var rawNames: [String: String] = [:]

    private let lock = NSLock()

    private init() {}

    // MARK: - Raw name cache

    func storeRawName(courseNo: String, name: String) {
        lock.withLock { rawNames[courseNo] = name }
    }

    func rawName(for courseNo: String) -> String? {
        lock.withLock { rawNames[courseNo] }
    }

    func clearRawNameCache() {
        lock.withLock { rawNames.removeAll() }
    }

    // MARK: - Abbreviation lookups

    /// Returns the abbreviated course name, or the original if no entry exists.
    func abbreviateName(_ rawName: String) -> String {
        ensureLoaded()
        return lock.withLock { courseAbbr[rawName] ?? rawName }
    }

    /// Abbreviates a classroom string (may be comma-separated).
    /// `display`: "original" | "pinyin" | "translated"
    func abbreviateClassroom(_ raw: String, display: String) -> String {
        guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return raw }
        ensureLoaded()
        let parts = SDCourse.splitRoom(raw)
        let abbreviated = lock.withLock {
            parts.map { part -> String in
                guard let entry = classroomAbbr[part] else { return part }
                let short = entry.shortenedName.trimmingCharacters(in: .whitespaces)
                let pinyin = entry.pinyin.trimmingCharacters(in: .whitespaces)
                let translated = entry.translated.trimmingCharacters(in: .whitespaces)
                let fallback = short.isEmpty ? part : short
                switch display {
                case "pinyin": return pinyin.isEmpty ? fallback : pinyin
                case "translated": return translated.isEmpty ? fallback : translated
                default: return fallback
                }
            }
        }
        return abbreviated.joined(separator: ", ")
    }

    // MARK: - Batch relabel

    /// Re-derives `courseName` and `classroom` on each course using the cached
    /// raw names. Mutates in-place. Returns `true` if any course changed.
    /// Only applies abbreviations when `LanguageManager.isCourseApiEnglish` is true.
    @discardableResult
    func relabelInPlace(
        _ courses: [SDCourse],
        courseAbbrEnabled: Bool,
        classroomAbbrEnabled: Bool,
        classroomMandarinDisplay: String
    ) -> Bool {
        var changed = false
        let isEnglish = LanguageManager.isCourseApiEnglish(
            appLanguage: Defaults[.appLanguage]
        )

        for course in courses {
            let raw = lock.withLock { rawNames[course.courseNo] } ?? course.courseName
            let newName: String
            if isEnglish && courseAbbrEnabled {
                newName = abbreviateName(raw)
            } else {
                newName = raw
            }

            let newClassroom = derivedClassroom(
                for: course,
                isEnglish: isEnglish,
                classroomAbbrEnabled: classroomAbbrEnabled,
                mandarinDisplay: classroomMandarinDisplay
            )

            if course.courseName != newName || course.classroom != newClassroom {
                course.courseName = newName
                course.classroom = newClassroom
                changed = true
            }
        }
        return changed
    }

    private func derivedClassroom(
        for course: SDCourse,
        isEnglish: Bool,
        classroomAbbrEnabled: Bool,
        mandarinDisplay: String
    ) -> String {
        let map = course.classroomMap
        if map.isEmpty {
            guard isEnglish && classroomAbbrEnabled else { return course.classroom }
            return abbreviateClassroom(course.classroom, display: mandarinDisplay)
        }

        var seen = Set<String>()
        var parts: [String] = []
        let sortedKeys = map.keys.sorted()
        for key in sortedKeys {
            guard let raw = map[key] else { continue }
            let abbr: String
            if isEnglish && classroomAbbrEnabled {
                abbr = abbreviateClassroom(raw, display: mandarinDisplay)
            } else if !isEnglish {
                abbr = abbreviateClassroom(raw, display: mandarinDisplay)
            } else {
                abbr = raw
            }
            for part in SDCourse.splitRoom(abbr) where !seen.contains(part) {
                seen.insert(part)
                parts.append(part)
            }
        }
        return parts.isEmpty ? course.classroom : parts.joined(separator: ", ")
    }

    // MARK: - Lazy load

    private func ensureLoaded() {
        lock.withLock {
            guard !abbrLoaded else { return }
            courseAbbr = loadCourseAbbr()
            classroomAbbr = loadClassroomAbbr()
            abbrLoaded = true
        }
    }

    private func loadCourseAbbr() -> [String: String] {
        guard let url = Bundle.main.url(forResource: "class-name-abbr", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    private func loadClassroomAbbr() -> [String: ClassroomAbbrEntry] {
        guard let url = Bundle.main.url(forResource: "classroom-name-abbr", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: ClassroomAbbrEntry].self, from: data) else {
            return [:]
        }
        return dict
    }
}

private struct ClassroomAbbrEntry: Decodable {
    let shortenedName: String
    let pinyin: String
    let translated: String

    enum CodingKeys: String, CodingKey {
        case shortenedName = "shortened_name"
        case pinyin
        case translated
    }
}
