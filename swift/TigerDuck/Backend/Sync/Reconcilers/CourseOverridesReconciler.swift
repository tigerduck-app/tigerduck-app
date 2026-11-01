import Foundation
import os

@MainActor
struct CourseOverridesReconciler: CategoryReconciler {
    static let category = "course_overrides"
    unowned let app: AppEnvironment

    func reconcile(_ pass: FullSyncPass) -> Bool {
        let colors = pass.taken.contains("course_colors")
        let names = pass.taken.contains("course_names")
        guard colors || names else {
            AppLogger.sync.info("[syncOverrides] skipping course overrides — switched off or conflict check pending")
            return false
        }
        let late = colors ? Self.lateMoodleColors(
            pass.courseOverrides, courses: pass.coursesArray, moved: CourseColorStore.shared.lateMoodleColors,
            snapshot: pass.json
        ) : (holding: [], sent: [])
        let choices = colors ? Self.colorChoices(
            pass.courseOverrides, courses: pass.coursesArray,
            holding: pass.heldCourseOverrides.colors.union(late.holding), snapshot: pass.json
        ) : []
        CourseColorStore.shared.endMoodleWaits(late.sent.union(choices), for: pass.signIn)
        let changed = !pass.courseOverrides.isEmpty && applyCourseOverrides(
            pass.courseOverrides, coursesArray: pass.coursesArray, colors: colors, names: names,
            holdingColors: pass.heldCourseOverrides.colors.union(late.holding),
            holdingNames: pass.heldCourseOverrides.names, for: pass.signIn
        )
        if colors {
            let fills = Self.colorFills(
                pass.courseOverrides, courses: pass.coursesArray, local: TigerDuckTheme.snapshot(),
                holding: pass.heldCourseOverrides.colors, snapshot: pass.json
            )
            if !fills.isEmpty {
                Task { [coordinator = app.cloudSyncCoordinator] in await coordinator.sendColorFills(fills, for: pass.signIn) }
            }
        }
        return changed
    }

    static func colorFills(
        _ overrides: [[String: Any]], courses: [[String: Any]], local: [String: UInt32],
        holding held: Set<String>, snapshot json: [String: Any]
    ) -> [CourseColorFill] {
        let byIdentity = overridesByIdentity(overrides)
        return courses.compactMap { row in
            guard let identity = Self.overrideIdentity(row), !held.contains(identity),
                  let semester = row["semester"] as? String, let courseNo = row["course_no"] as? String,
                  let hex = local[courseNo] else { return nil }
            let override = byIdentity[identity]
            let serverHex = (override?["color_hex"] as? String).flatMap { UInt32($0.dropFirst(), radix: 16) }
            let serverClock = (override?["color_hex_hlc"] as? NSNumber)?.int64Value
            guard serverHex != hex else { return nil }
            let stamp = deterministicFillStamp(
                serverHasColor: serverHex != nil, stampedAt: serverClock, snapshot: json, semester: semester
            )
            guard serverClock.map({ $0 < PushAPI.clock(of: stamp) }) ?? true else { return nil }
            return CourseColorFill(
                courseKey: row["course_key"] as? String ?? CourseTombstone.serverKey(semester: semester, courseNo: courseNo),
                courseNo: courseNo, identity: identity, colorHex: String(format: "#%06X", hex), stamp: stamp
            )
        }
    }

    /// For the courses a late Moodle id moved here: `holding`, those whose backend colour is
    /// still another automatic fill, which keep the move for `colorFills` to stamp just after it;
    /// `sent`, those whose backend colour is the move or newer than a fill, which need no more.
    static func lateMoodleColors(
        _ overrides: [[String: Any]], courses: [[String: Any]], moved: [String: UInt32], snapshot json: [String: Any]
    ) -> (holding: Set<String>, sent: Set<String>) {
        let byIdentity = overridesByIdentity(overrides)
        var late: (holding: Set<String>, sent: Set<String>) = ([], [])
        for row in courses {
            guard let identity = overrideIdentity(row), let semester = row["semester"] as? String,
                  let courseNo = row["course_no"] as? String, let hex = moved[courseNo],
                  let override = byIdentity[identity],
                  let serverHex = (override["color_hex"] as? String).flatMap({ UInt32($0.dropFirst(), radix: 16) }),
                  let clock = (override["color_hex_hlc"] as? NSNumber)?.int64Value else { continue }
            let fill = deterministicFillStamp(serverHasColor: false, stampedAt: nil, snapshot: json, semester: semester)
            if serverHex != hex && clock <= PushAPI.clock(of: fill) {
                late.holding.insert(identity)
            } else {
                late.sent.insert(courseNo)
            }
        }
        return late
    }

    /// The courses whose backend colour is stamped after an automatic fill, so a device chose it.
    /// A fill of this device comes back on every pull and ends no wait.
    static func colorChoices(
        _ overrides: [[String: Any]], courses: [[String: Any]], holding held: Set<String>, snapshot json: [String: Any]
    ) -> Set<String> {
        let byIdentity = overridesByIdentity(overrides)
        return Set(courses.compactMap { row in
            guard let identity = overrideIdentity(row), !held.contains(identity),
                  let semester = row["semester"] as? String, let courseNo = row["course_no"] as? String,
                  let colorHex = byIdentity[identity]?["color_hex"] as? String, !colorHex.isEmpty,
                  let clock = (byIdentity[identity]?["color_hex_hlc"] as? NSNumber)?.int64Value else { return nil }
            let fill = deterministicFillStamp(serverHasColor: false, stampedAt: nil, snapshot: json, semester: semester)
            return clock > PushAPI.clock(of: fill) ? courseNo : nil
        })
    }

    private static func overridesByIdentity(_ overrides: [[String: Any]]) -> [String: [String: Any]] {
        Dictionary(
            overrides.compactMap { row in overrideIdentity(row).map { ($0, row) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    static func deterministicFillStamp(
        serverHasColor: Bool, stampedAt serverClock: Int64?, snapshot json: [String: Any], semester: String
    ) -> Date {
        let after = serverHasColor ? (serverClock ?? 0) : (coveringReset(json, semester: semester) ?? 0)
        return Date(timeIntervalSince1970: Double(after + fillStep) / 1_000_000)
    }

    /// A millisecond: a microsecond could be lost on the way through `Date`'s seconds.
    static let fillStep: Int64 = 1_000

    static func coveringReset(_ json: [String: Any], semester: String) -> Int64? {
        let full = (json["courses_reset_hlc"] as? NSNumber)?.int64Value
        let term = ((json["term_resets"] as? [String: Any])?[semester] as? NSNumber)?.int64Value
        return [full, term].compactMap { $0 }.max()
    }

    private func applyCourseOverrides(
        _ overrides: [[String: Any]], coursesArray: [[String: Any]], colors: Bool, names: Bool,
        holdingColors: Set<String>, holdingNames: Set<String>, for signIn: SignIn
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
            Self.serverCourseColors(overrides, courseNos: moodleIdToNo, holding: holdingColors), for: signIn
        )
        let namesBefore = CourseStore.shared.loadCourseCustomNames()
        let customNames = names
            ? Self.courseNamesAfterPull(overrides, courseNos: moodleIdToNo, local: namesBefore, holding: holdingNames)
            : namesBefore
        let namesChanged = customNames != namesBefore
        if namesChanged {
            CourseStore.shared.saveCourseCustomNames(customNames, for: signIn)
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
                  let serverNames = setOrClearedNames(in: o), !serverNames.isEmpty
            else { continue }
            var existing = names[courseNo] ?? [:]
            for (locale, name) in serverNames { existing[locale] = name }
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

    nonisolated static func setOrClearedNames(in row: [String: Any]) -> [String: String?]? {
        (row["custom_names"] as? [String: String])?.mapValues { $0.isEmpty ? nil : $0 }
    }

    nonisolated static func overrideIdentity(_ row: [String: Any]) -> String? {
        if let moodleId = row["moodle_id"] as? String ?? (row["moodle_id"] as? Int).map(String.init), !moodleId.isEmpty {
            return moodleId
        }
        guard let semester = row["semester"] as? String, let courseNo = row["course_no"] as? String,
              !semester.isEmpty, !courseNo.isEmpty else { return nil }
        return "\(semester)\(courseNo)"
    }
}

nonisolated struct CourseColorFill: Equatable, Sendable {
    let courseKey: String
    let courseNo: String
    let identity: String
    let colorHex: String
    let stamp: Date
}
