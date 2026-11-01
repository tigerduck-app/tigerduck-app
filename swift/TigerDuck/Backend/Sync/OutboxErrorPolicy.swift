import Foundation

enum OutboxErrorPolicy {
    static func parksAtOnce(_ error: Error, for op: SyncOp) -> Bool {
        switch op {
        case .courseOverride where error is CourseKeyUnknownError:
            return true
        case .courseOverride, .courseIgnore:
            guard case PushAPIError.httpStatus(404, _, _) = error else { return false }
            return (error as? PushAPIError)?.code == "course_not_found"
        case .assignmentOverride, .courseDelete, .courseAdd:
            return false
        }
    }

    static func keepsWithoutAttempt(_ error: Error, for op: SyncOp) -> Bool {
        if case .courseAdd = op, case PushAPIError.httpStatus(_, _, _) = error { return false }
        if case .courseDelete = op, case PushAPIError.httpStatus(409, _, _) = error { return true }
        return keepsWithoutAttempt(error)
    }

    static func keepsWithoutAttempt(_ error: Error) -> Bool {
        switch error {
        case is CancellationError, is URLError:
            return true
        case let auth as SyncOutboxAuthError:
            return auth.statusCode == 401
        case PushAPIError.httpStatus(let code, _, _):
            return code == 408 || code == 429 || (500..<600).contains(code)
        default:
            return false
        }
    }
}
