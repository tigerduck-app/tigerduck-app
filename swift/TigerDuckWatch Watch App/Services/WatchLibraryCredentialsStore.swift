import Foundation
import Combine

@MainActor
final class WatchLibraryCredentialsStore: ObservableObject {

    static let shared = WatchLibraryCredentialsStore()

    @Published private(set) var hasCredentials: Bool

    private let defaults: UserDefaults

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

    enum ApplyResult: Equatable {
        case applied
        case rejectedReplay
        case malformed
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
                return .malformed
            }
        }

        defaults.set(payload.credEpoch, forKey: DefaultsKey.credEpoch)
        defaults.set(payload.issuedAtMs, forKey: DefaultsKey.issuedAtMs)
        hasCredentials = (payload.kind == .set)
        return .applied
    }

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

    func storedEpoch() -> Int {
        defaults.integer(forKey: DefaultsKey.credEpoch)
    }

    func storedIssuedAtMs() -> Int64 {
        Int64(defaults.double(forKey: DefaultsKey.issuedAtMs))
    }

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

    #if DEBUG
    func _resetForTests() {
        wipe()
    }
    #endif
}
