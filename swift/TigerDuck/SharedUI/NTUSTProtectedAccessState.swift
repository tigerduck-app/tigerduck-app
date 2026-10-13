import Foundation

/// View-side rendering state for a surface behind the NTUST portal login. It
/// holds only the cases a view renders; reauthentication and its failures
/// surface through ``AppState`` banners, so the enum stays small and every
/// consumer has a branch for every case.
///
/// Consumers never construct it. ``AppState/ntustProtectedAccessState(isEmpty:)``
/// derives it from stored credentials and empty data, cached first: with stored
/// credentials, cached data renders even while cookies are refreshed.
enum NTUSTProtectedAccessState: Equatable, Sendable {
    case loginRequired
    case content
    case empty
}
