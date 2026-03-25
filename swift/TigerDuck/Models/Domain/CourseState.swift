import Foundation

enum CourseState: Equatable {
    case inClass(SDCourse)
    case between(previous: SDCourse?, next: SDCourse?)
    case beforeFirst(next: SDCourse)
    case afterLast(previous: SDCourse)

    static func == (lhs: CourseState, rhs: CourseState) -> Bool {
        switch (lhs, rhs) {
        case (.inClass(let a), .inClass(let b)):
            return a.courseNo == b.courseNo
        case (.between(let lp, let ln), .between(let rp, let rn)):
            return lp?.courseNo == rp?.courseNo && ln?.courseNo == rn?.courseNo
        case (.beforeFirst(let a), .beforeFirst(let b)):
            return a.courseNo == b.courseNo
        case (.afterLast(let a), .afterLast(let b)):
            return a.courseNo == b.courseNo
        default:
            return false
        }
    }
}
