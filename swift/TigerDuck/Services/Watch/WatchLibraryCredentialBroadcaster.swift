import Foundation
import WatchConnectivity
import os

/// Phone-side sender of library-credential push events to the paired
/// watch. Owns the monotonic `credEpoch` (App Group `UserDefaults`)
/// and uses `WCSession.transferUserInfo` for FIFO, guaranteed delivery.
///
/// Singleton because `LibraryService` is an `enum` (no instance to
/// inject through). All public surface is `@MainActor`; the actual WC
/// send is non-isolated under the hood.
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
    /// holds this epoch). Used by `WatchSyncBridge` on appear so a
    /// TTL-purged watch recovers credentials the next time the phone
    /// foregrounds, without any explicit user action.
    func republishIfCredentialed() {
        guard let username = LibraryService.storedUsername,
              let password = LibraryService.storedPasswordIfAvailable() else {
            return
        }
        // Don't advance the epoch — re-send with the same epoch.
        let epoch = currentEpoch()
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
        defaults.integer(forKey: DefaultsKey.epoch)
    }

    private func nextEpoch() -> Int {
        let next = currentEpoch() + 1
        defaults.set(next, forKey: DefaultsKey.epoch)
        return next
    }

    private func send(_ payload: WatchLibraryCredentialPayload) {
        if !session.isPaired || !session.isWatchAppInstalled {
            logger.notice("watch not present; transferUserInfo will queue for delivery anyway")
            // transferUserInfo will queue and deliver when the watch
            // appears, so we still call it.
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
