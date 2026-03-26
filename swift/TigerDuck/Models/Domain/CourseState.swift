import Foundation

enum CourseState: Equatable {
    case inClass(CourseTimeSlot)
    case between(previous: CourseTimeSlot?, next: CourseTimeSlot?)
    case beforeFirst(next: CourseTimeSlot)
    case afterLast(previous: CourseTimeSlot)

    static func == (lhs: CourseState, rhs: CourseState) -> Bool {
        switch (lhs, rhs) {
        case (.inClass(let a), .inClass(let b)):
            return a.id == b.id
        case (.between(let lp, let ln), .between(let rp, let rn)):
            return lp?.id == rp?.id && ln?.id == rn?.id
        case (.beforeFirst(let a), .beforeFirst(let b)):
            return a.id == b.id
        case (.afterLast(let a), .afterLast(let b)):
            return a.id == b.id
        default:
            return false
        }
    }
}
