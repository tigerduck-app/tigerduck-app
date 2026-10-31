import Foundation

/// How the outbox treats an op's failed send: parked for the next course upload, kept for
/// another try without spending an attempt, or counted.
enum OutboxErrorPolicy {
    /// A course's colour, name or ignore setting the backend cannot place yet, 404
    /// `course_not_found` as the upload that adds the course has not landed, or a colour or name
    /// whose course this device cannot name, waits parked for the next course upload.
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
        // The backend answers a course delete 409 only for its stamp, so another code is not a
        // refusal of the delete, which a later attempt may still land.
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
