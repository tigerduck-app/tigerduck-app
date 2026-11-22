import Foundation
import Testing
@testable import TigerDuckWatch_Watch_App

/// Serialized: the store keeps its credential in the Watch's Keychain, which every test shares.
@Suite("Watch library code", .serialized)
@MainActor
struct WatchLibraryCodeTests {
    private static let code = "https://example.invalid/demo-library-code"

    private static func credential(epoch: Int, code: String?) -> WatchLibraryCredentialPayload {
        WatchLibraryCredentialPayload(
            kind: .set, credEpoch: epoch, issuedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            username: "B11000000", password: "password", code: code
        )
    }

    /// The test host's phone is never reachable and its library requests fail at `SchoolNetworkGuard`,
    /// so a code shown with no error came from the store.
    @Test("a credential sent with a code shows that code without asking the phone or the library")
    func theCodeShowsWithNoRequest() async throws {
        try #require(SchoolNetworkGuard.isInstalled)
        LibraryQRCache.shared.clear()
        let suiteName = "WatchLibraryCodeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = WatchLibraryCredentialsStore(defaults: defaults)
        store._resetForTests()
        defer {
            store._resetForTests()
            LibraryQRCache.shared.clear()
        }

        #expect(store.apply(Self.credential(epoch: 1, code: Self.code)) == .applied)
        #expect(store.fixedCode() == Self.code)
        let model = LibraryQRViewModel(store: store)
        model.onAppear()
        defer { model.onDisappear() }
        for _ in 0..<600 where model.qrImage == nil && model.error == nil {
            try await Task.sleep(for: .milliseconds(100))
        }

        #expect(model.error == nil)
        #expect(model.qrImage != nil)
        #expect(LibraryQRCache.shared.reusable() == Self.code)
    }

    @Test("a credential without a code, and a wipe, drop the code an earlier one came with")
    func aLaterCredentialDropsTheCode() throws {
        let suiteName = "WatchLibraryCodeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = WatchLibraryCredentialsStore(defaults: defaults)
        store._resetForTests()
        defer { store._resetForTests() }

        #expect(store.apply(Self.credential(epoch: 1, code: Self.code)) == .applied)
        #expect(store.apply(Self.credential(epoch: 2, code: nil)) == .applied)
        #expect(store.fixedCode() == nil)

        #expect(store.apply(Self.credential(epoch: 3, code: Self.code)) == .applied)
        let wipe = WatchLibraryCredentialPayload(
            kind: .wipe, credEpoch: 4, issuedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
        #expect(store.apply(wipe) == .applied)
        #expect(store.fixedCode() == nil)
    }
}
