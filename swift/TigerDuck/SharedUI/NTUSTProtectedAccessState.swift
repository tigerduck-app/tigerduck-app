import Foundation

/// View-side rendering state for a 校務系統-protected surface. Represents
/// *only* the cases a view currently needs to render — broader auth state
/// (reauthenticating, reauth failures) is surfaced separately through
/// ``AppState`` banners so the enum stays small and every case has a
/// corresponding branch in every consumer.
///
/// Consumers do NOT construct this value directly. The single source of
/// truth is ``AppState/ntustProtectedAccessState(isEmpty:)`` — it folds
/// "credentials stored?" and "data empty?" together following the
/// cached-first rule: if credentials exist, cached data is always
/// rendered even while cookies are being refreshed.
enum NTUSTProtectedAccessState: Equatable, Sendable {
    case loginRequired
    case content
    case empty
}
