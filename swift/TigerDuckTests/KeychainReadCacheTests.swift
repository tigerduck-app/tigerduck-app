import Foundation
import os
import Testing
@testable import TigerDuck

/// `DebugEndpointStore` answers every backend request's URL from this cache, so it must read the
/// Keychain once, and read it again after a change or an unlock.
struct KeychainReadCacheTests {

    /// Hands out `values` in turn and counts the reads.
    private final class FakeKeychain: Sendable {
        private let state: OSAllocatedUnfairLock<(values: [String?], reads: Int)>
        init(_ values: [String?]) { state = OSAllocatedUnfairLock(initialState: (values, 0)) }
        var reads: Int { state.withLock { $0.reads } }
        func read() -> String? {
            state.withLock { state in
                let value = state.values.isEmpty ? nil : state.values.removeFirst()
                state.reads += 1
                return value
            }
        }
    }

    @Test func readsTheKeychainOnce() {
        let keychain = FakeKeychain(["https://a.example", "https://b.example"])
        let cache = KeychainReadCache(load: { keychain.read() })

        #expect(cache.value() == "https://a.example")
        #expect(cache.value() == "https://a.example")
        #expect(keychain.reads == 1)
    }

    /// Before the first unlock after a restart the read fails, and kept as "no override" it would
    /// send a self-hosting user's background syncs to the production backend until an unlock
    /// notification the suspended app may never get
    /// (https://github.com/tigerduck-app/tigerduck-app/issues/488).
    @Test func doesNotKeepAReadThatCouldNotReachTheKeychain() {
        let unreadable = OSAllocatedUnfairLock(initialState: true)
        let cache = KeychainReadCache(load: {
            if unreadable.withLock({ $0 }) { throw CocoaError(.fileReadNoPermission) }
            return "https://a.example"
        })

        #expect(cache.value() == nil)
        unreadable.withLock { $0 = false }
        #expect(cache.value() == "https://a.example")
    }

    @Test func keepsAReadThatFoundNothing() {
        let keychain = FakeKeychain([nil, "https://a.example"])
        let cache = KeychainReadCache(load: { keychain.read() })

        #expect(cache.value() == nil)
        #expect(cache.value() == nil)
        #expect(keychain.reads == 1)
    }

    @Test func forgetReadsTheKeychainAgain() {
        let keychain = FakeKeychain(["https://a.example", nil])
        let cache = KeychainReadCache(load: { keychain.read() })
        _ = cache.value()

        cache.forget()

        #expect(cache.value() == nil)
        #expect(keychain.reads == 2)
    }

    /// A launch behind a locked screen reads nothing; the unlock notification brings the value.
    @Test func aGivenNotificationReadsTheKeychainAgain() {
        let center = NotificationCenter()
        let unlocked = Notification.Name("KeychainReadCacheTests.unlocked")
        let keychain = FakeKeychain([nil, "https://a.example"])
        let cache = KeychainReadCache(load: { keychain.read() }, forgetOn: [unlocked], center: center)
        #expect(cache.value() == nil)

        center.post(name: unlocked, object: nil)

        #expect(cache.value() == "https://a.example")
    }

    /// A change that lands while a read is under way must not be hidden by the older value.
    @Test func aReadAChangeOvertookIsNotKept() {
        let keychain = FakeKeychain(["https://old.example", "https://new.example"])
        let holder = OSAllocatedUnfairLock<KeychainReadCache?>(initialState: nil)
        let cache = KeychainReadCache(load: {
            let value = keychain.read()
            if keychain.reads == 1 { holder.withLock { $0 }?.forget() }
            return value
        })
        holder.withLock { $0 = cache }

        #expect(cache.value() == "https://old.example")
        #expect(cache.value() == "https://new.example")
        #expect(keychain.reads == 2)
    }
}
