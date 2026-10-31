import Foundation
import Defaults

final class NameAbbrService: @unchecked Sendable {
    static let shared = NameAbbrService()

    private var courseAbbr: [String: String] = [:]
    private var classroomAbbr: [String: ClassroomAbbrEntry] = [:]
    private var classroomReverseIndex: [String: String] = [:]
    private var abbrLoaded = false

    private var rawNames: [String: String] = [:]
    private var rawClassrooms: [String: String] = [:]
    private var rawClassroomMaps: [String: [String: String]] = [:]

    private let lock = NSLock()

    private init() {}

    func storeRawName(courseNo: String, name: String) {
        lock.withLock { rawNames[courseNo] = name }
    }

    func rawName(for courseNo: String) -> String? {
        lock.withLock { rawNames[courseNo] }
    }

    func storeRawClassroom(courseNo: String, classroom: String, map: [String: String]) {
        lock.withLock {
            rawClassrooms[courseNo] = classroom
            rawClassroomMaps[courseNo] = map
        }
    }

    func clearRawNameCache() {
        lock.withLock {
            rawNames.removeAll()
            rawClassrooms.removeAll()
            rawClassroomMaps.removeAll()
        }
    }

    func abbreviateName(_ rawName: String) -> String {
        ensureLoaded()
        return lock.withLock { courseAbbr[rawName] ?? rawName }
    }

    func abbreviateClassroom(_ raw: String, display: String) -> String {
        guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return raw }
        ensureLoaded()
        let parts = SDCourse.splitRoom(raw)
        let abbreviated = lock.withLock {
            parts.map { part -> String in
                let key = classroomKey(for: part)
                guard let entry = classroomAbbr[key] else { return part }
                let short = entry.shortenedName.trimmingCharacters(in: .whitespaces)
                let pinyin = entry.pinyin.trimmingCharacters(in: .whitespaces)
                let translated = entry.translated.trimmingCharacters(in: .whitespaces)
                let fallback = short.isEmpty ? key : short
                switch display {
                case "pinyin": return pinyin.isEmpty ? fallback : pinyin
                case "translated": return translated.isEmpty ? fallback : translated
                default: return fallback
                }
            }
        }
        return abbreviated.joined(separator: ", ")
    }

    func rawClassroom(_ shown: String) -> String {
        ensureLoaded()
        return lock.withLock { classroomKey(for: shown) }
    }

    private func classroomKey(for part: String) -> String {
        classroomAbbr[part] != nil ? part : (classroomReverseIndex[part] ?? part)
    }

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

            let (newClassroom, newMap) = derivedClassroom(
                for: course,
                classroomAbbrEnabled: classroomAbbrEnabled,
                mandarinDisplay: classroomMandarinDisplay
            )

            if course.courseName != newName
                || course.classroom != newClassroom
                || course.classroomMap != newMap {
                course.courseName = newName
                course.classroom = newClassroom
                course.setClassroomMap(newMap)
                changed = true
            }
        }
        return changed
    }

    private func derivedClassroom(
        for course: SDCourse,
        classroomAbbrEnabled: Bool,
        mandarinDisplay: String
    ) -> (classroom: String, map: [String: String]) {
        let shouldAbbreviate = classroomAbbrEnabled || mandarinDisplay != "original"

        let rawFlat = lock.withLock { rawClassrooms[course.courseNo] } ?? course.classroom
        let rawMap = lock.withLock { rawClassroomMaps[course.courseNo] } ?? course.classroomMap

        let derivedMap: [String: String]
        if rawMap.isEmpty {
            derivedMap = [:]
        } else if shouldAbbreviate {
            derivedMap = rawMap.mapValues { abbreviateClassroom($0, display: mandarinDisplay) }
        } else {
            derivedMap = rawMap
        }

        if derivedMap.isEmpty {
            let flat = shouldAbbreviate
                ? abbreviateClassroom(rawFlat, display: mandarinDisplay)
                : rawFlat
            return (flat, [:])
        }

        var seen = Set<String>()
        var parts: [String] = []
        for key in derivedMap.keys.sorted() {
            guard let value = derivedMap[key] else { continue }
            for part in SDCourse.splitRoom(value) where !seen.contains(part) {
                seen.insert(part)
                parts.append(part)
            }
        }
        let flat = parts.isEmpty ? rawFlat : parts.joined(separator: ", ")
        return (flat, derivedMap)
    }

    private func ensureLoaded() {
        lock.withLock {
            guard !abbrLoaded else { return }
            courseAbbr = loadCourseAbbr()
            classroomAbbr = loadClassroomAbbr()
            classroomReverseIndex = buildClassroomReverseIndex(classroomAbbr)
            abbrLoaded = true
        }
    }

    private func buildClassroomReverseIndex(
        _ entries: [String: ClassroomAbbrEntry]
    ) -> [String: String] {
        var index: [String: String] = [:]
        for (key, entry) in entries {
            for form in [entry.shortenedName, entry.pinyin, entry.translated] {
                let trimmed = form.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, trimmed != key, index[trimmed] == nil else { continue }
                index[trimmed] = key
            }
        }
        return index
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
