import Foundation

enum CourseState: Equatable {
    /// Every slot whose window contains the resolved time.
    ///
    /// A list rather than one slot because two courses can 衝堂 — occupy
    /// the same period — and keeping only the first match showed one of
    /// them and silently dropped the other, with which one survived
    /// falling out of timeline order rather than anything the reader could
    /// see. Ordered by start, so a consumer that genuinely wants a single
    /// class (a Live Activity shows one) takes `first` and gets the
    /// earliest. Never empty: the no-class cases are the other four.
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
