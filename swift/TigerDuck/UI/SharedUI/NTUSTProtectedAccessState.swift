import Foundation

enum NTUSTProtectedAccessState: Equatable, Sendable {
    case loginRequired
    case content
    case empty

    init(signedIn: Bool, isEmpty: Bool) {
        self = !signedIn ? .loginRequired : isEmpty ? .empty : .content
    }
}
