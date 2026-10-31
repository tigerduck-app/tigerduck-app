import Foundation
import os

/// Course colours and names, each while its switch is on and no edit of it is queued here.
@MainActor
struct CourseOverridesReconciler: CategoryReconciler {
    let category = "course_overrides"

    func reconcile(_ pass: FullSyncPass) -> Bool {
        let colors = pass.taken.contains("course_colors")
        let names = pass.taken.contains("course_names")
        guard colors || names else {
            AppLogger.sync.info("[syncOverrides] skipping course overrides — switched off or conflict check pending")
            return false
        }
        guard !pass.courseOverrides.isEmpty else { return false }
        return applyCourseOverrides(
            pass.courseOverrides, coursesArray: pass.coursesArray, colors: colors, names: names,
            holdingColors: pass.heldCourseOverrides.colors, holdingNames: pass.heldCourseOverrides.names
        )
    }

    private func applyCourseOverrides(
        _ overrides: [[String: Any]], coursesArray: [[String: Any]], colors: Bool, names: Bool,
        holdingColors: Set<String>, holdingNames: Set<String>
    ) -> Bool {
        var moodleIdToNo: [String: String] = [:]
        for c in coursesArray {
            guard let mId = Self.overrideIdentity(c) else { continue }
            if let courseNo = c["course_no"] as? String, !courseNo.isEmpty {
                moodleIdToNo[mId] = courseNo
            } else if let name = c["course_name"] as? String, let bracketEnd = name.firstIndex(of: "】") {
                let rest = name[name.index(after: bracketEnd)...].trimmingCharacters(in: .whitespaces)
                let code = rest.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
                if !code.isEmpty { moodleIdToNo[mId] = code }
            }
        }
        AppLogger.sync.info("moodleIdToNo: \(moodleIdToNo.count, privacy: .public) entries, overrides: \(overrides.count, privacy: .public)")

        let colorsChanged = colors && TigerDuckTheme.applyColors(
            Self.serverCourseColors(overrides, courseNos: moodleIdToNo, holding: holdingColors)
        )
        let namesBefore = CourseStore.shared.loadCourseCustomNames()
        let customNames = names
            ? Self.courseNamesAfterPull(overrides, courseNos: moodleIdToNo, local: namesBefore, holding: holdingNames)
            : namesBefore
        let namesChanged = customNames != namesBefore
        if namesChanged {
            CourseStore.shared.saveCourseCustomNames(customNames)
        }
        return colorsChanged || namesChanged
    }

    nonisolated static func courseNamesAfterPull(
        _ overrides: [[String: Any]],
        courseNos: [String: String],
        local: [String: [String: String]],
        holding held: Set<String>
    ) -> [String: [String: String]] {
        var names = local
        for o in overrides {
            guard let mId = overrideIdentity(o), !held.contains(mId),
                  let courseNo = o["course_no"] as? String ?? courseNos[mId],
                  let serverNames = o["custom_names"] as? [String: String], !serverNames.isEmpty
            else { continue }
            var existing = names[courseNo] ?? [:]
            for (locale, name) in serverNames {
                if name.isEmpty {
                    existing.removeValue(forKey: locale)
                } else {
                    existing[locale] = name
                }
            }
            names[courseNo] = existing.isEmpty ? nil : existing
        }
        return names
    }

    static func serverCourseColors(
        _ overrides: [[String: Any]],
        courseNos: [String: String],
        holding held: Set<String>
    ) -> [(courseNo: String, hex: UInt32)] {
        let rows = overrides.compactMap { o -> (courseNo: String, hex: UInt32, at: Date)? in
            guard let mId = overrideIdentity(o), !held.contains(mId),
                  let courseNo = o["course_no"] as? String ?? courseNos[mId],
                  let colorHex = o["color_hex"] as? String, !colorHex.isEmpty,
                  let hex = UInt32(colorHex.dropFirst(), radix: 16) else { return nil }
            let at = (o["color_hex_updated_at"] as? String).flatMap {
                TigerDuckDateFormatters.withFractional.date(from: $0)
                    ?? TigerDuckDateFormatters.withoutFractional.date(from: $0)
            } ?? .distantPast
            return (courseNo, hex, at)
        }
        return rows.sorted { ($0.at, $0.courseNo) < ($1.at, $1.courseNo) }.map { ($0.courseNo, $0.hex) }
    }

    /// How a snapshot's course or override row names its course, as this device's edits do: the
    /// Moodle id number, or the term and the number when it has none.
    nonisolated static func overrideIdentity(_ row: [String: Any]) -> String? {
        if let moodleId = row["moodle_id"] as? String ?? (row["moodle_id"] as? Int).map(String.init), !moodleId.isEmpty {
            return moodleId
        }
        guard let semester = row["semester"] as? String, let courseNo = row["course_no"] as? String,
              !semester.isEmpty, !courseNo.isEmpty else { return nil }
        return "\(semester)\(courseNo)"
    }
}
