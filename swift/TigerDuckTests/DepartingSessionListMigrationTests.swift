import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct DepartingSessionListMigrationTests {
    private static let earlier = #"{"refreshToken":"R0","uses":1,"baseURL":"https:\/\/api.example.test\/v3"}"#

    @Test("a session an earlier version kept becomes the only entry of the list, once")
    func theEarlierSessionBecomesTheOnlyEntry() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        var stored: String? = Self.earlier

        DepartingSessionListMigration.runIfNeeded(defaults: defaults, read: { stored }, write: { stored = $0; return true })

        #expect(stored == "[\(Self.earlier)]")
        let converted = stored
        let manager = AuthTokenManager(
            baseURLProvider: { URL(string: "https://api.example.test/v3")! },
            deviceUUID: "test-device",
            tokens: .init(load: { $0 == AuthTokenManager.departingSessionKey ? converted : nil }, save: { _, _ in }, delete: { _ in })
        )
        #expect(manager.departingSessionBackends == [URL(string: "https://api.example.test/v3")!])
        stored = Self.earlier
        DepartingSessionListMigration.runIfNeeded(defaults: defaults, read: { stored }, write: { stored = $0; return true })
        #expect(stored == Self.earlier)
    }

    @Test("a keychain it cannot read or write leaves the migration for the next launch")
    func aFailedReadOrWriteRunsAgain() throws {
        struct Locked: Error {}
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        var stored: String? = Self.earlier

        DepartingSessionListMigration.runIfNeeded(defaults: defaults, read: { throw Locked() }, write: { stored = $0; return true })
        DepartingSessionListMigration.runIfNeeded(defaults: defaults, read: { stored }, write: { _ in false })
        #expect(stored == Self.earlier)

        DepartingSessionListMigration.runIfNeeded(defaults: defaults, read: { stored }, write: { stored = $0; return true })
        #expect(stored == "[\(Self.earlier)]")
    }
}
