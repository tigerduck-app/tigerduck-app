import Foundation
#if os(watchOS)
@testable import TigerDuckWatch_Watch_App
#else
@testable import TigerDuck
#endif

/// XCTest creates the bundle's principal class when it loads the bundle, before any test runs; the
/// phone and Watch test targets' `INFOPLIST_KEY_NSPrincipalClass` names this one.
@objc(TigerDuckTestsSetup)
nonisolated final class TestBundleSetup: NSObject {
    override init() {
        super.init()
        SchoolNetworkGuard.install()
    }
}
