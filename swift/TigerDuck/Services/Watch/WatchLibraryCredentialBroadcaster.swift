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
    /// holds this epoch). Recovers two cases:
    /// 1. Watch never received the original set (was off when phone logged in).
    /// 2. Watch ran TTL purge — which clears `credEpoch` on the watch, so
    ///    this same-epoch payload now satisfies `payload.credEpoch >
    ///    storedEpoch` (since storedEpoch is back to 0) and applies cleanly.
    func republishIfCredentialed() {
        guard let username = LibraryService.storedUsername,
              let password = LibraryService.storedPasswordIfAvailable() else {
            return
        }
        let epoch = currentEpoch()
        // Skip if epoch is 0 — phone never broadcast a set, so there's
        // nothing to republish (and the watch wouldn't accept epoch 0
        // anyway because `0 > 0` is false).
        guard epoch > 0 else { return }
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
