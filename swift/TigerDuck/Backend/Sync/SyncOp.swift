import Foundation

nonisolated enum SyncOp: Codable, Sendable {
    case courseOverride(semester: String, moodleId: String, customName: String?, colorHex: String?, locale: String?, stamp: Date)
    case assignmentOverride(moodleCourseId: Int, moodleAssignmentId: Int, localStatus: String, stamp: Date)
    case courseIgnore(semester: String, courseNo: String, moodleId: String, moodleCourseId: Int?, ignore: Bool?, stamp: Date)
    case courseDelete(semester: String, courseNo: String, stamp: Date)
    case courseAdd(semester: String, courseNo: String, stamp: Date)

    private enum CodingKeys: String, CodingKey {
        case courseOverride, assignmentOverride, courseIgnore, courseDelete, courseAdd
    }
    private enum CourseOverrideKeys: String, CodingKey {
        case semester, moodleId, courseKey, customName, colorHex, locale, stamp
    }
    private enum AssignmentOverrideKeys: String, CodingKey {
        case moodleCourseId, moodleAssignmentId, localStatus, stamp
    }
    private enum CourseIgnoreKeys: String, CodingKey {
        case semester, courseNo, moodleId, moodleCourseId, ignore, stamp
    }
    private enum CourseKeys: String, CodingKey {
        case semester, courseNo, stamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.courseOverride) {
            let c = try container.nestedContainer(keyedBy: CourseOverrideKeys.self, forKey: .courseOverride)
            let moodleId = try c.decodeIfPresent(String.self, forKey: .moodleId)
                ?? c.decode(String.self, forKey: .courseKey)
            self = .courseOverride(
                semester: try c.decode(String.self, forKey: .semester),
                moodleId: moodleId,
                customName: try c.decodeIfPresent(String.self, forKey: .customName),
                colorHex: try c.decodeIfPresent(String.self, forKey: .colorHex),
                locale: try c.decodeIfPresent(String.self, forKey: .locale),
                stamp: try c.decode(Date.self, forKey: .stamp))
        } else if container.contains(.assignmentOverride) {
            let c = try container.nestedContainer(keyedBy: AssignmentOverrideKeys.self, forKey: .assignmentOverride)
            self = .assignmentOverride(
                moodleCourseId: try c.decode(Int.self, forKey: .moodleCourseId),
                moodleAssignmentId: try c.decode(Int.self, forKey: .moodleAssignmentId),
                localStatus: try c.decode(String.self, forKey: .localStatus),
                stamp: try c.decode(Date.self, forKey: .stamp))
        } else if container.contains(.courseIgnore) {
            let c = try container.nestedContainer(keyedBy: CourseIgnoreKeys.self, forKey: .courseIgnore)
            self = .courseIgnore(
                semester: try c.decode(String.self, forKey: .semester),
                courseNo: try c.decode(String.self, forKey: .courseNo),
                moodleId: try c.decode(String.self, forKey: .moodleId),
                moodleCourseId: try c.decodeIfPresent(Int.self, forKey: .moodleCourseId),
                ignore: try c.decodeIfPresent(Bool.self, forKey: .ignore),
                stamp: try c.decode(Date.self, forKey: .stamp))
        } else if container.contains(.courseDelete) {
            let c = try container.nestedContainer(keyedBy: CourseKeys.self, forKey: .courseDelete)
            self = .courseDelete(
                semester: try c.decode(String.self, forKey: .semester),
                courseNo: try c.decode(String.self, forKey: .courseNo),
                stamp: try c.decode(Date.self, forKey: .stamp))
        } else if container.contains(.courseAdd) {
            let c = try container.nestedContainer(keyedBy: CourseKeys.self, forKey: .courseAdd)
            self = .courseAdd(
                semester: try c.decode(String.self, forKey: .semester),
                courseNo: try c.decode(String.self, forKey: .courseNo),
                stamp: try c.decode(Date.self, forKey: .stamp))
        } else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown SyncOp case"))
        }
    }

    var dedupKey: String {
        switch self {
        case .courseOverride(let semester, let moodleId, let customName, let colorHex, let locale, _):
            let fields = [
                customName != nil ? "n" : "",
                colorHex != nil ? "c" : "",
            ].joined()
            return "co|\(semester)|\(moodleId)|\(fields)|\(locale ?? "")"
        case .assignmentOverride(let moodleCourseId, let moodleAssignmentId, _, _):
            return "ao|\(moodleCourseId)|\(moodleAssignmentId)"
        case .courseIgnore(let semester, _, let moodleId, _, _, _):
            return "ci|\(semester)|\(moodleId)"
        case .courseDelete(let semester, let courseNo, _):
            return "cd|\(semester)|\(courseNo)"
        case .courseAdd(let semester, let courseNo, _):
            return "ca|\(semester)|\(courseNo)"
        }
    }

    var stamp: Date {
        switch self {
        case .courseOverride(_, _, _, _, _, let stamp), .assignmentOverride(_, _, _, let stamp),
             .courseIgnore(_, _, _, _, _, let stamp), .courseDelete(_, _, let stamp), .courseAdd(_, _, let stamp):
            return stamp
        }
    }

    var discardScopes: [DiscardScope] {
        switch self {
        case .courseOverride(_, _, let customName, let colorHex, _, _):
            return (colorHex != nil ? [.courseColors] : []) + (customName != nil ? [.courseNames] : [])
        case .assignmentOverride:
            return [.assignmentMarks]
        case .courseIgnore:
            return [.courseIgnores]
        case .courseDelete(let semester, let courseNo, _):
            return [
                .allCourseDeletes, .courseDeletes(term: semester),
                .courseDelete(key: CourseTombstone.key(semester: semester, courseNo: courseNo)),
            ]
        case .courseAdd:
            return [.allCourseAdds]
        }
    }
}

nonisolated enum DiscardScope: Hashable, Sendable {
    case assignmentMarks, courseColors, courseNames, courseIgnores
    case allCourseAdds
    case allCourseDeletes, courseDeletes(term: String), courseDelete(key: String)
}

nonisolated struct DiscardCutoffs: Sendable {
    private var byScope: [DiscardScope: Date]

    init(_ byScope: [DiscardScope: Date] = [:]) {
        self.byScope = byScope
    }

    mutating func keep(_ cutoffs: [DiscardScope: Date], notAfter now: Date) {
        byScope.merge(cutoffs.mapValues { min($0, now) }, uniquingKeysWith: max)
    }

    func cutsOff(_ op: SyncOp) -> Bool {
        op.discardScopes.contains { scope in byScope[scope].map { op.stamp < $0 } ?? false }
    }
}

/// `signIn` is the sign-in the op was made in. An entry read back from disk has none and goes out
/// with the drain's, as a sign-out clears the outbox before the next account signs in.
nonisolated struct OutboxEntry: Codable, Sendable {
    let id: UUID
    let op: SyncOp
    var attempts: Int
    var signIn: SignIn?

    private enum CodingKeys: String, CodingKey {
        case id, op, attempts
    }
}
