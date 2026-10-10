import Foundation

enum CourseState: Equatable {
    /// Every slot whose window contains the resolved time.
    ///
    /// A list because two courses can clash (occupy the same period), and
    /// keeping only the first match would silently drop one, picked by
    /// timeline order rather than anything the reader can see. Ordered by
    /// start, so a consumer that wants one class (a Live Activity shows one)
    /// takes `first` and gets the earliest. Never empty: the other cases cover
    /// having no class.
    case inClass([CourseTimeSlot])
    case between(previous: CourseTimeSlot?, next: CourseTimeSlot?)
    case beforeFirst(next: CourseTimeSlot)
    case afterLast(previous: CourseTimeSlot)

    static func == (lhs: CourseState, rhs: CourseState) -> Bool {
        switch (lhs, rhs) {
        case (.inClass(let a), .inClass(let b)):
            return a.map(\.id) == b.map(\.id)
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
