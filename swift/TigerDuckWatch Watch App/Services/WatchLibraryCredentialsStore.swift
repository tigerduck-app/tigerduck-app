import Foundation
import Combine

/// Watch-side owner of library credentials, token, epoch, and TTL state.
///
/// * Receives `WatchLibraryCredentialPayload` from the WC delegate and keeps
///   username and password in the watch keychain (`WatchKeychain`).
/// * Keeps the credential epoch in App Group `UserDefaults`, so a fresh install
///   resets it to 0 and a phone reinstall re-syncs cleanly (`republishIfCredentialed`).
/// * A 7-day TTL purge keeps credentials from outliving the phone install if
///   WC delivery never lands.
@MainActor
final class WatchLibraryCredentialsStore: ObservableObject {

    static let shared = WatchLibraryCredentialsStore()

    @Published private(set) var hasCredentials: Bool

    private let defaults: UserDefaults

    /// Bounded staleness for credentials we have not heard a fresh
    /// `set` for. 7 days picked to comfortably cover travel, finals
    /// week, and the holiday period without keeping credentials around
    /// forever if WC never re-delivers.
    static let credentialTTL: TimeInterval = 7 * 24 * 60 * 60

    enum Keys {
        static let username = "watch_library_username"
        static let password = "watch_library_password"
        static let token = "watch_library_token"
        static let tokenExpiryMs = "watch_library_token_expiry_ms"
    }

    enum DefaultsKey {
        static let credEpoch = "watch_library_cred_epoch"
        static let issuedAtMs = "watch_library_cred_issued_at_ms"
    }

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? SharedAppGroup.defaults
        self.hasCredentials = WatchKeychain.string(forKey: Keys.username) != nil
            && WatchKeychain.string(forKey: Keys.password) != nil
    }

    // MARK: - Payload application

    enum ApplyResult: Equatable {
        case applied
        case rejectedReplay     // payload.credEpoch <= stored
        case malformed          // .set without username/password
    }

    @discardableResult
    func apply(_ payload: WatchLibraryCredentialPayload) -> ApplyResult {
        let stored = storedEpoch()
        guard payload.credEpoch > stored else { return .rejectedReplay }

        switch payload.kind {
        case .set:
            guard let u = payload.username, !u.isEmpty,
                  let p = payload.password, !p.isEmpty else {
                return .malformed
            }
            clearToken()
            guard WatchKeychain.set(u, forKey: Keys.username),
                  WatchKeychain.set(p, forKey: Keys.password) else {
                return .malformed
            }
        case .wipe:
            guard wipeKeychainOnly(), clearToken() else {
                // Keychain remove can fail if the watch is locked
                // (whenUnlockedThisDeviceOnly). Don't advance the epoch
                // so the phone's next republish retries the wipe.
                return .malformed
            }
        }

        defaults.set(payload.credEpoch, forKey: DefaultsKey.credEpoch)
        defaults.set(payload.issuedAtMs, forKey: DefaultsKey.issuedAtMs)
        hasCredentials = (payload.kind == .set)
        return .applied
    }

    // MARK: - Token cache (writes happen in WatchLibraryService)

    func storeToken(_ token: String, expiryMs: Int64) {
        WatchKeychain.set(token, forKey: Keys.token)
        WatchKeychain.set(String(expiryMs), forKey: Keys.tokenExpiryMs)
    }

    func loadToken() -> (token: String, expiryMs: Int64)? {
        guard let t = WatchKeychain.string(forKey: Keys.token),
              let s = WatchKeychain.string(forKey: Keys.tokenExpiryMs),
              let ms = Int64(s) else { return nil }
        return (t, ms)
    }

    @discardableResult
    func clearToken() -> Bool {
        let t = WatchKeychain.remove(forKey: Keys.token)
        let e = WatchKeychain.remove(forKey: Keys.tokenExpiryMs)
        return t && e
    }

    // MARK: - Reads with TTL gate

    func storedEpoch() -> Int {
        defaults.integer(forKey: DefaultsKey.credEpoch)
    }

    func storedIssuedAtMs() -> Int64 {
        Int64(defaults.double(forKey: DefaultsKey.issuedAtMs))
    }

    /// Returns credentials only within the 7-day TTL window. Stale ones are
    /// wiped locally so the next push from the phone starts a fresh state.
    ///
    /// `issuedAtMs == 0` with credentials present means the keychain outlived
    /// the App Group `UserDefaults`: watchOS keeps the keychain across an
    /// uninstall and reinstall but resets defaults. Such orphans have no TTL
    /// anchor, so they count as expired until the next phone push sets a clean
    /// epoch and `issuedAtMs`.
    func loadCredentialsRespectingTTL(now: Date = Date()) -> (username: String, password: String)? {
        guard let u = WatchKeychain.string(forKey: Keys.username),
              let p = WatchKeychain.string(forKey: Keys.password) else {
            return nil
        }

        let issuedMs = storedIssuedAtMs()
        if issuedMs <= 0 {
            wipe()
            return nil
        }

        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let ageMs = nowMs - issuedMs
        if Double(ageMs) > Self.credentialTTL * 1000 {
            wipe()
            return nil
        }

        return (u, p)
    }

    func currentUsername() -> String? {
        WatchKeychain.string(forKey: Keys.username)
    }

    // MARK: - Wipes

    /// Local-only wipe used by the TTL purge (and `_resetForTests`). Clears
    /// credentials, token cache, *and* the epoch/issuedAt markers so the
    /// next phone push — including the broadcaster's
    /// `republishIfCredentialed`, which re-sends the same epoch — is
    /// applied rather than rejected as replay. The wire-format `.wipe`
    /// payload deliberately does NOT call this; it routes through
    /// `wipeKeychainOnly()` so the monotonic epoch keeps protecting
    /// against out-of-order delivery.
    func wipe() {
        wipeKeychainOnly()
        clearToken()
        defaults.removeObject(forKey: DefaultsKey.credEpoch)
        defaults.removeObject(forKey: DefaultsKey.issuedAtMs)
        hasCredentials = false
    }

    @discardableResult
    private func wipeKeychainOnly() -> Bool {
        let u = WatchKeychain.remove(forKey: Keys.username)
        let p = WatchKeychain.remove(forKey: Keys.password)
        return u && p
    }

    // MARK: - Testing helpers

    #if DEBUG
    func _resetForTests() {
        wipe()
    }
    #endif
}
