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

    @Test("a keychain it cannot write leaves the migration for the next launch")
    func aFailedWriteRunsAgain() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        var stored: String? = Self.earlier

        DepartingSessionListMigration.runIfNeeded(defaults: defaults, read: { stored }, write: { _ in false })
        #expect(stored == Self.earlier)

        DepartingSessionListMigration.runIfNeeded(defaults: defaults, read: { stored }, write: { stored = $0; return true })
        #expect(stored == "[\(Self.earlier)]")
    }

    @Test("a keychain it cannot read runs it again in the same process once protected data is readable")
    func anUnreadableKeychainRunsItAgainWhenReadable() throws {
        struct Locked: Error {}
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let center = NotificationCenter()
        var stored: String? = Self.earlier
        var readable = false

        DepartingSessionListMigration.runIfNeeded(
            defaults: defaults, center: center,
            read: {
                guard readable else { throw Locked() }
                return stored
            },
            write: { stored = $0; return true }
        )
        #expect(stored == Self.earlier)

        readable = true
        center.post(name: DepartingSessionListMigration.readableAgain, object: nil)

        #expect(stored == "[\(Self.earlier)]")
    }
}
