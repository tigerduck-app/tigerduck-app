import Foundation

/// Shared access state for NTUST-protected surfaces. Distinguishes "user is
/// not logged in" from "logged in but no data", so views never confuse an
/// access gate with a genuine empty state.
enum NTUSTProtectedAccessState: Equatable, Sendable {
    case loading
    case loginRequired
    case content
    case empty
    case error(String)

    /// Convenience for the common case where a surface only needs to decide
    /// between login-required, empty, and content.
    init(isLoggedIn: Bool, isEmpty: Bool) {
        if !isLoggedIn {
            self = .loginRequired
        } else if isEmpty {
            self = .empty
        } else {
            self = .content
        }
    }
}
