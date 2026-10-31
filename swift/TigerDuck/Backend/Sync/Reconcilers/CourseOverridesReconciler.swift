import Foundation
import os

/// Course colours and names, each while its switch is on and no edit of it is queued here.
@MainActor
struct CourseOverridesReconciler: CategoryReconciler {
    static let category = "course_overrides"
    unowned let app: AppState

    func reconcile(_ pass: FullSyncPass) -> Bool {
        let colors = pass.taken.contains("course_colors")
        let names = pass.taken.contains("course_names")
        guard colors || names else {
            AppLogger.sync.info("[syncOverrides] skipping course overrides — switched off or conflict check pending")
            return false
        }
        let changed = !pass.courseOverrides.isEmpty && app.applyCourseOverrides(
            pass.courseOverrides, coursesArray: pass.coursesArray, colors: colors, names: names,
            holdingColors: pass.heldCourseOverrides.colors, holdingNames: pass.heldCourseOverrides.names
        )
        if colors {
            let fills = Self.colorFills(
                pass.courseOverrides, courses: pass.coursesArray, local: TigerDuckTheme.snapshot(),
                holding: pass.heldCourseOverrides.colors, snapshot: pass.json
            )
            if !fills.isEmpty {
                Task { [coordinator = app.cloudSyncCoordinator] in await coordinator.sendColorFills(fills) }
            }
        }
        return changed
    }

    /// The colours this device sends once a snapshot's are applied: its own for a course the
    /// backend holds none for, and the one a course moved to here because a course applied after
    /// it holds the same. Each goes stamped just after the term's latest reset or the colour it
    /// replaces, a stamp every device reads alike from the snapshot, so the first to land wins
    /// and the others take its colour back, while a pick, stamped when it was made, beats it.
    static func colorFills(
        _ overrides: [[String: Any]], courses: [[String: Any]], local: [String: UInt32],
        holding held: Set<String>, snapshot json: [String: Any]
    ) -> [CourseColorFill] {
        let byIdentity = Dictionary(
            overrides.compactMap { row in AppState.overrideIdentity(row).map { ($0, row) } },
            uniquingKeysWith: { first, _ in first }
        )
        return courses.compactMap { row in
            guard let identity = AppState.overrideIdentity(row), !held.contains(identity),
                  let semester = row["semester"] as? String, let courseNo = row["course_no"] as? String,
                  let hex = local[courseNo] else { return nil }
            let override = byIdentity[identity]
            let serverHex = (override?["color_hex"] as? String).flatMap { UInt32($0.dropFirst(), radix: 16) }
            let serverClock = (override?["color_hex_hlc"] as? NSNumber)?.int64Value
            guard serverHex != hex else { return nil }
            let after = serverHex != nil ? (serverClock ?? 0) : (coveringReset(json, semester: semester) ?? 0)
            let stamp = Date(timeIntervalSince1970: Double(after + fillStep) / 1_000_000)
            guard serverClock.map({ $0 < PushAPI.clock(of: stamp) }) ?? true else { return nil }
            return CourseColorFill(
                courseKey: row["course_key"] as? String ?? CourseTombstone.serverKey(semester: semester, courseNo: courseNo),
                courseNo: courseNo, identity: identity, colorHex: String(format: "#%06X", hex), stamp: stamp
            )
        }
    }

    /// A millisecond: a microsecond could be lost on the way through `Date`'s seconds.
    static let fillStep: Int64 = 1_000

    /// The later of the snapshot's full reset and the term's own, as a TigerSync clock value.
    static func coveringReset(_ json: [String: Any], semester: String) -> Int64? {
        let full = (json["courses_reset_hlc"] as? NSNumber)?.int64Value
        let term = ((json["term_resets"] as? [String: Any])?[semester] as? NSNumber)?.int64Value
        return [full, term].compactMap { $0 }.max()
    }
}

/// A course colour a full sync sends with the stamp `CourseOverridesReconciler.colorFills` gave it.
nonisolated struct CourseColorFill: Equatable, Sendable {
    let courseKey: String
    let courseNo: String
    let identity: String
    let colorHex: String
    let stamp: Date
}
