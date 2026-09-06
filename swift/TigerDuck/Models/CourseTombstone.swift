import Foundation

/// Hidden-course ("deleted") tombstone keys, persisted as plain strings in
/// `deleted_courses.json`.
///
/// A key is `"<semester>:<courseNo>"`, so hiding a course in 115-1 leaves
/// the same course number alone in every other term (a retaken course
/// reuses its number). Entries written before the semester scope existed
/// are a bare course number and are honoured as "hidden in every
/// semester" rather than migrated — the per-term cache needed to attribute
/// them is not guaranteed to exist at upgrade time. Un-hiding or resetting
/// drops both shapes, after which every write is scoped.
nonisolated enum CourseTombstone {
    static func key(semester: String, courseNo: String) -> String {
        "\(semester):\(courseNo)"
    }

    static func isHidden(_ courseNo: String, semester: String, in tombstones: Set<String>) -> Bool {
        tombstones.contains(courseNo)
            || tombstones.contains(key(semester: semester, courseNo: courseNo))
    }

    /// Removes the scoped key and any legacy bare entry for `courseNo`.
    /// Returns whether anything was removed.
    @discardableResult
    static func unhide(_ courseNo: String, semester: String, from tombstones: inout Set<String>) -> Bool {
        let scoped = tombstones.remove(key(semester: semester, courseNo: courseNo)) != nil
        let legacy = tombstones.remove(courseNo) != nil
        return scoped || legacy
    }

    /// What a reset of `semester` drops: its scoped keys plus every legacy
    /// bare entry (those hide in all terms, so a reset has to lift them).
    static func entries(resetting semester: String, in tombstones: Set<String>) -> Set<String> {
        tombstones.filter { $0.hasPrefix("\(semester):") || !$0.contains(":") }
    }

    /// Upgrade path for stores written before the semester scope: a bare
    /// entry is pinned to every term whose roster carries the course, so
    /// the per-semester sync sees one scoped key per term instead of a
    /// global wildcard. An entry no roster knows stays bare (still hidden
    /// everywhere) until a roster turns up. Order is not significant.
    static func migratingLegacyEntries(_ entries: [String], rosters: [String: Set<String>]) -> [String] {
        var result = Set(entries)
        for courseNo in entries where !courseNo.contains(":") {
            let terms = rosters.filter { $0.value.contains(courseNo) }.keys
            guard !terms.isEmpty else { continue }
            result.remove(courseNo)
            for semester in terms {
                result.insert(key(semester: semester, courseNo: courseNo))
            }
        }
        return Array(result)
    }
}
