import Foundation

nonisolated enum CourseTombstone {
    static func key(semester: String, courseNo: String) -> String {
        "\(semester):\(courseNo)"
    }

    static func serverKey(semester: String, courseNo: String) -> String {
        serverKey(of: key(semester: semester, courseNo: courseNo))
    }

    static func serverKey(of key: String) -> String {
        "client:" + key
    }

    static func parts(of key: String) -> (semester: String, courseNo: String)? {
        guard let colon = key.firstIndex(of: ":") else { return nil }
        return (String(key[..<colon]), String(key[key.index(after: colon)...]))
    }

    static func isHidden(_ courseNo: String, semester: String, in tombstones: Set<String>) -> Bool {
        tombstones.contains(courseNo)
            || tombstones.contains(key(semester: semester, courseNo: courseNo))
    }

    @discardableResult
    static func unhide(_ courseNo: String, semester: String, from tombstones: inout Set<String>) -> Bool {
        let scoped = tombstones.remove(key(semester: semester, courseNo: courseNo)) != nil
        let legacy = tombstones.remove(courseNo) != nil
        return scoped || legacy
    }

    static func entries(resetting semester: String, in tombstones: Set<String>) -> Set<String> {
        tombstones.filter { $0.hasPrefix("\(semester):") || !$0.contains(":") }
    }

    static func courseNos(hiddenIn semester: String, in tombstones: Set<String>) -> Set<String> {
        let prefix = key(semester: semester, courseNo: "")
        return Set(entries(resetting: semester, in: tombstones).map {
            $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : $0
        })
    }

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
