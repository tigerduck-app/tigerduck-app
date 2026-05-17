import Foundation

/// User preference for how external URLs (announcement attachments, library
/// catalogue links, NTUST help pages, etc.) open: in the system browser or
/// in an in-app web view.
///
/// Extracted from `AppState` so the type is available on every platform
/// without dragging `AppState`'s iOS-only push / live-activity dependencies
/// into the cross-platform compile graph.
enum BrowserPreference: String, CaseIterable {
    case system
    case inApp
}
