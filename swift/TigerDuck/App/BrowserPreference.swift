import Foundation

enum BrowserPreference: String, CaseIterable {
    case system
    case inApp
}

enum BrowserAddressBar: String, CaseIterable {
    case top
    case bottom
}

/// What the TigerDuck browser's store holds: nothing, the signed-in account's data, or data a
/// sign-in or sign-out could not remove, which the next browser clears before it loads.
enum BrowserDataState: String {
    case empty
    case used
    case stale
}
