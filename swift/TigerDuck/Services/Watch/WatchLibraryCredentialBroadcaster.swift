import Foundation
import WatchConnectivity
import os

/// Phone-side sender of library-credential push events to the paired
/// watch. Owns the monotonic `credEpoch` (App Group `UserDefaults`) and
/// uses `WCSession.transferUserInfo` for FIFO, guaranteed delivery.
///
/// MainActor-isolated: the only callers (`LibraryService.saveCredentials`
/// /`clearCredentials` and `WatchSyncBridge.pushNow`) are all on the main
/// actor, and synchronous MainActor → MainActor calls avoid the deferred-
/// `Task` race we hit in the original Combine-style broadcast path.
@MainActor
final class WatchLibraryCredentialBroadcaster {

    static let shared = WatchLibraryCredentialBroadcaster()

    private let session: WatchSessionPushing
    private let defaults: UserDefaults
    private let logger = Logger(
        subsystem: "org.ntust.app.TigerDuck",
        category: "watch.credBroadcast"
    )

    private enum DefaultsKey {
        static let epoch = "watchLibraryCredEpoch"
    }

    init(
        session: WatchSessionPushing? = nil,
        defaults: UserDefaults? = nil
    ) {
        self.session = session ?? WCSession.default
        self.defaults = defaults ?? UserDefaults(suiteName: "group.org.ntust.app.TigerDuck") ?? .standard
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

    /// Re-emits the current credentials if the phone still has them. Idempotent on the watch,
    /// which rejects a replay of an epoch it already holds. Recovers three cases:
    /// 1. The watch never got the original set: it was off when the phone logged in.
    /// 2. The watch ran its TTL purge, which resets its stored epoch to 0, so this same-epoch
    ///    payload passes `payload.credEpoch > storedEpoch` and applies.
    /// 3. An upgrade with credentials already in the iPhone keychain: `credEpoch` defaults to
    ///    0, which the watch rejects, so the first run with stored credentials bootstraps to
    ///    the next epoch.
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

    private func nextEpoch() -> Int {
        let next = defaults.integer(forKey: DefaultsKey.epoch) + 1
        defaults.set(next, forKey: DefaultsKey.epoch)
        return next
    }

    /// Used by `republishIfCredentialed`: reuse the current epoch when one
    /// has been broadcast, but bootstrap to epoch 1 if defaults still hold
    /// the install-time 0 (existing user upgraded with credentials already
    /// in keychain). Returns the same epoch on subsequent calls so a chatty
    /// `pushNow` doesn't burn through fresh epochs on every accent/lang flip.
    private func republishEpoch() -> Int {
        let current = defaults.integer(forKey: DefaultsKey.epoch)
        if current > 0 { return current }
        let bootstrapped = 1
        defaults.set(bootstrapped, forKey: DefaultsKey.epoch)
        return bootstrapped
    }

    private func send(_ payload: WatchLibraryCredentialPayload) {
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
        // Always queue transferUserInfo (durable, FIFO), so an apply that fails on the watch,
        // like a wipe on a locked keychain, runs again; sendMessage confirms transport only. If
        // reachable, also sendMessage for speed; the epoch guard drops the duplicate.
        _ = session.transferUserInfo(userInfo)
        if session.isReachable {
            session.sendMessage(userInfo, replyHandler: nil) { [weak self] error in
                // sendMessage's error handler fires on a background queue;
                // hop to MainActor so we don't cross self's actor isolation.
                Task { @MainActor [weak self] in
                    self?.logger.error(
                        "sendMessage failed: \(error.localizedDescription); transferUserInfo will still deliver"
                    )
                }
            }
        }
    }
}
