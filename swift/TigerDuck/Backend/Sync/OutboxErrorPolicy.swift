import Foundation

enum OutboxErrorPolicy {
    static func waitsForCourseUpload(_ error: Error, for op: SyncOp) -> Bool {
        switch op {
        case .courseOverride where error is CourseKeyUnknownError:
            return true
        case .courseOverride, .courseIgnore:
            guard case PushAPIError.courseNotFound = error else { return false }
            return true
        case .assignmentOverride, .courseDelete, .courseAdd:
            return false
        }
    }

    static func keepsWithoutAttempt(_ error: Error, for op: SyncOp) -> Bool {
        if case .courseAdd = op, case PushAPIError.httpStatus(_, _, _) = error { return false }
        if case .courseDelete = op, isStampConflict(error) { return true }
        return keepsWithoutAttempt(error)
    }

    private static func isStampConflict(_ error: Error) -> Bool {
        guard case PushAPIError.httpStatus(409, _, _) = error else { return false }
        return true
    }

    static func keepsWithoutAttempt(_ error: Error) -> Bool {
        switch error {
        case is CancellationError, is URLError:
            return true
        case let auth as SyncOutboxAuthError:
            return auth.statusCode == 401
        case PushAPIError.httpStatus(let code, _, _):
            return code == 408 || code == 429 || (500..<600).contains(code)
        case PushAPIError.clockAhead(serverClock: nil):
            return true
        default:
            return false
        }
    }
}
