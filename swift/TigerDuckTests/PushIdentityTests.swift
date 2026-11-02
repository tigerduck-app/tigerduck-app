import Foundation
import Testing
import os
@testable import TigerDuck

struct PushIdentityTests {
    private static let idKey = AppConstants.KeychainKeys.pushDeviceId
    private static let secretKey = AppConstants.KeychainKeys.pushDeviceSecret
    private static let uuidPattern = #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#
    private static let secretPattern = #"^[A-Za-z0-9_-]{43}$"#

    @Test("a first launch mints a device id and a 43-character base64url secret, and saves both")
    func aFirstLaunchMintsAndSavesBoth() throws {
        let keychain = FakeIdentityKeychain()

        let identity = PushIdentity.loadOrCreate(from: keychain.store)

        #expect(identity.uuid.range(of: Self.uuidPattern, options: .regularExpression) != nil)
        let secret = try #require(identity.secret)
        #expect(secret.range(of: Self.secretPattern, options: .regularExpression) != nil)
        #expect(identity.mayAnnounce)
        #expect(keychain[Self.idKey] == identity.uuid)
        #expect(keychain[Self.secretKey] == secret)
    }

    @Test("an updated app that holds a device id keeps it and mints only a secret")
    func aStoredIdGainsASecret() throws {
        let keychain = FakeIdentityKeychain([Self.idKey: "kept-device"])

        let identity = PushIdentity.loadOrCreate(from: keychain.store)

        #expect(identity.uuid == "kept-device")
        #expect(try #require(identity.secret).count == 43)
        #expect(keychain[Self.secretKey] == identity.secret)
    }

    @Test("a later launch, after a reinstall too, reads the same id and secret")
    func aLaterLaunchReadsBoth() {
        let keychain = FakeIdentityKeychain([Self.idKey: "kept-device", Self.secretKey: "kept-secret"])

        let identity = PushIdentity.loadOrCreate(from: keychain.store)

        #expect(identity.uuid == "kept-device")
        #expect(identity.secret == "kept-secret")
        #expect(identity.mayAnnounce)
        #expect(keychain.saves.isEmpty)
    }

    @Test("a secret left without its device id is replaced along with a new id")
    func anOrphanSecretIsMintedAgain() {
        let keychain = FakeIdentityKeychain([Self.secretKey: "orphan-secret"])

        let identity = PushIdentity.loadOrCreate(from: keychain.store)

        #expect(identity.secret != "orphan-secret")
        #expect(keychain[Self.secretKey] == identity.secret)
        #expect(keychain[Self.idKey] == identity.uuid)
    }

    @Test("a secret that cannot be saved is not used, and a later launch mints one again")
    func anUnsavedSecretIsNotUsed() throws {
        let keychain = FakeIdentityKeychain([Self.idKey: "kept-device"], unsavable: [Self.secretKey])

        let unsaved = PushIdentity.loadOrCreate(from: keychain.store)

        #expect(unsaved.uuid == "kept-device")
        #expect(unsaved.secret == nil)
        #expect(unsaved.mayAnnounce)
        keychain.unsavable = []
        let later = PushIdentity.loadOrCreate(from: keychain.store)
        #expect(try #require(later.secret).count == 43)
        #expect(keychain[Self.secretKey] == later.secret)
    }

    @Test("a Keychain that cannot be read yet mints nothing and announces nothing", arguments: [idKey, secretKey])
    func anUnreadableKeychainMintsNothing(unreadable: String) {
        let keychain = FakeIdentityKeychain([Self.idKey: "kept-device"], unreadable: [unreadable])

        let identity = PushIdentity.loadOrCreate(from: keychain.store)

        #expect(!identity.mayAnnounce)
        #expect(identity.secret == nil)
        #expect(keychain.saves.isEmpty)
    }

    @Test("each minted secret is new")
    func mintedSecretsDiffer() {
        let secrets = (0..<8).compactMap { _ in PushIdentity.mintSecret() }

        #expect(Set(secrets).count == 8)
    }
}

/// `PushIdentity.Store` over a dictionary, with keys that throw on a read or fail a save.
nonisolated final class FakeIdentityKeychain: Sendable {
    private struct State {
        var items: [String: String]
        var saves: [String] = []
        var unsavable: Set<String>
    }

    private let state: OSAllocatedUnfairLock<State>
    private let unreadable: Set<String>

    init(_ items: [String: String] = [:], unreadable: Set<String> = [], unsavable: Set<String> = []) {
        state = .init(initialState: State(items: items, unsavable: unsavable))
        self.unreadable = unreadable
    }

    struct Unreadable: Error {}

    subscript(key: String) -> String? { state.withLock { $0.items[key] } }

    var saves: [String] { state.withLock { $0.saves } }

    var unsavable: Set<String> {
        get { state.withLock { $0.unsavable } }
        set { state.withLock { $0.unsavable = newValue } }
    }

    var store: PushIdentity.Store {
        PushIdentity.Store(
            read: { [self] key in
                if unreadable.contains(key) { throw Unreadable() }
                return self[key]
            },
            save: { [state] key, value in
                state.withLock {
                    guard !$0.unsavable.contains(key) else { return false }
                    $0.items[key] = value
                    $0.saves.append(key)
                    return true
                }
            },
            delete: { [state] key in state.withLock { $0.items[key] = nil } }
        )
    }
}
