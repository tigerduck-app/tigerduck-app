import Foundation

enum NTUSTProtectedAccessState: Equatable, Sendable {
    case loginRequired
    case content
    case empty
}
