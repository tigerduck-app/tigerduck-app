import Foundation

enum BrowserPreference: String, CaseIterable {
    case system
    case inApp
}

/// Where the TigerDuck browser puts its address bar.
enum BrowserAddressBar: String, CaseIterable {
    case top
    case bottom
}
