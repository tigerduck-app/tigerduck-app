import Foundation
import Testing
@testable import TigerDuckWatch_Watch_App

/// The Watch's library seams left at their defaults stop at `SchoolNetworkGuard`, which names them
/// and sends nothing. Serialized: `capturing` takes what the guard stops from every test meanwhile.
@Suite("Watch school network guard", .serialized)
@MainActor
struct WatchSchoolNetworkGuardTests {
    @Test("the test host is one where the library seam refuses from launch")
    func hostRefusesFromLaunch() {
        #expect(ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil)
    }

    @Test("the library sign-in stops before the session")
    func librarySignIn() async throws {
        try #require(SchoolNetworkGuard.isInstalled)
        let blocked = await SchoolNetworkGuard.capturing {
            _ = await #expect(throws: (any Error).self) {
                try await WatchLibraryService.requestToken(username: "B11000000", password: "password")
            }
        }

        #expect(blocked.map(\.seam) == ["library sign-in"])
        #expect(blocked.map(\.target) == ["POST api.lib.ntust.edu.tw/v1/passport/login"])
    }

    @Test("the library code request stops before the session")
    func libraryCodeRequest() async throws {
        try #require(SchoolNetworkGuard.isInstalled)
        let blocked = await SchoolNetworkGuard.capturing {
            _ = await #expect(throws: (any Error).self) {
                try await WatchLibraryService.requestQRCode(token: "library-token")
            }
        }

        #expect(blocked.map(\.seam) == ["library code request"])
    }
}
