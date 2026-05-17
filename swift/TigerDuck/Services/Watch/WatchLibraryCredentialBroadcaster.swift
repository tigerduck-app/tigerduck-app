import Foundation
import WatchConnectivity
import os

/// Phone-side sender of library-credential push events to the paired
/// watch. Owns the monotonic `credEpoch` (App Group `UserDefaults`)
/// and uses `WCSession.transferUserInfo` for FIFO, guaranteed delivery.
///
/// Non-isolated by design: callers reach this from both `@MainActor`
/// (UI tap → logout) and background actors (token refresh background
/// task → re-save). The epoch counter is protected by an unfair lock so
/// the read-modify-write of `credEpoch` is atomic across call sites;
/// `WCSession.transferUserInfo(_:)` is documented thread-safe.
final class WatchLibraryCredentialBroadcaster: @unchecked Sendable {

    static let shared = WatchLibraryCredentialBroadcaster()

    private let session: WatchSessionPushing
    private let defaults: UserDefaults
    private let logger = Logger(
        subsystem: "org.ntust.app.TigerDuck",
        category: "watch.credBroadcast"
    )
    private let epochLock = OSAllocatedUnfairLock<Void>(initialState: ())

    private enum DefaultsKey {
        static let epoch = "watchLibraryCredEpoch"
    }

    init(
        session: WatchSessionPushing = WCSession.default,
        defaults: UserDefaults = UserDefaults(suiteName: "group.org.ntust.app.TigerDuck") ?? .standard
    ) {
        self.session = session
        self.defaults = defaults
    }

    // MARK: - Public

    func broadcastSet(username: String, password: String) {
        let epoch = nextEpoch()
        let payload = WatchLibraryCredentialPayload(
            kind: .set,
            credEpoch: epoch,
            issuedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            username: username,
            password: password
        )
        send(payload)
    }

    func broadcastWipe() {
        let epoch = nextEpoch()
        let payload = WatchLibraryCredentialPayload(
            kind: .wipe,
            credEpoch: epoch,
            issuedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
        send(payload)
    }

    /// Re-emit the current credentials if the phone still has them.
    /// Idempotent on the watch (rejected-as-replay if the watch already
    /// holds this epoch). Recovers three cases:
    /// 1. Watch never received the original set (was off when phone logged in).
    /// 2. Watch ran TTL purge — which clears `credEpoch` on the watch, so
    ///    this same-epoch payload now satisfies `payload.credEpoch >
    ///    storedEpoch` (since storedEpoch is back to 0) and applies cleanly.
    /// 3. Existing user upgraded with credentials already in the iPhone
    ///    keychain from before this code shipped — `credEpoch` defaults to
    ///    0, but the watch won't accept epoch 0, so we bootstrap to the
    ///    next epoch the first time this path runs with stored credentials.
    func republishIfCredentialed() {
        guard let username = LibraryService.storedUsername,
              let password = LibraryService.storedPasswordIfAvailable() else {
            return
        }
        let epoch = republishEpoch()
        let payload = WatchLibraryCredentialPayload(
            kind: .set,
            credEpoch: epoch,
            issuedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            username: username,
            password: password
        )
        send(payload)
    }

    // MARK: - Internals

    private func currentEpoch() -> Int {
        epochLock.withLock { defaults.integer(forKey: DefaultsKey.epoch) }
    }

    private func nextEpoch() -> Int {
        epochLock.withLock {
            let next = defaults.integer(forKey: DefaultsKey.epoch) + 1
            defaults.set(next, forKey: DefaultsKey.epoch)
            return next
        }
    }

    /// Used by `republishIfCredentialed`: reuse the current epoch when one
    /// has been broadcast, but bootstrap to epoch 1 if defaults still hold
    /// the install-time 0 (existing user upgraded with credentials already
    /// in keychain). Returns the same epoch on subsequent calls so a chatty
    /// `pushNow` doesn't burn through fresh epochs on every accent/lang flip.
    private func republishEpoch() -> Int {
        epochLock.withLock {
            let current = defaults.integer(forKey: DefaultsKey.epoch)
            if current > 0 { return current }
            let bootstrapped = 1
            defaults.set(bootstrapped, forKey: DefaultsKey.epoch)
            return bootstrapped
        }
    }

    private func send(_ payload: WatchLibraryCredentialPayload) {
        if !session.isPaired || !session.isWatchAppInstalled {
            logger.notice("watch not present; transferUserInfo will queue for delivery anyway")
        }
        let json: String
        do {
            json = try payload.encodedJSON()
        } catch {
            logger.error("payload encode failed: \(error.localizedDescription)")
            return
        }
        let userInfo: [String: Any] = [
            WatchWireFormat.LibraryCredentialKey.kind: WatchWireFormat.UserInfoKind.libraryCredential,
            WatchWireFormat.LibraryCredentialKey.payload: json,
        ]
        _ = session.transferUserInfo(userInfo)
        logger.notice("broadcast \(payload.kind.rawValue, privacy: .public) epoch=\(payload.credEpoch)")
    }
}
