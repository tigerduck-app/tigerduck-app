import Foundation
import WatchConnectivity
import os

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

    private func nextEpoch() -> Int {
        let next = defaults.integer(forKey: DefaultsKey.epoch) + 1
        defaults.set(next, forKey: DefaultsKey.epoch)
        return next
    }

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
        _ = session.transferUserInfo(userInfo)
        if session.isReachable {
            session.sendMessage(userInfo, replyHandler: nil) { [weak self] error in
                Task { @MainActor [weak self] in
                    self?.logger.error(
                        "sendMessage failed: \(error.localizedDescription); transferUserInfo will still deliver"
                    )
                }
            }
        }
    }
}
        // Always queue transferUserInfo (durable, FIFO), so an apply that fails on the watch,
        // like a wipe on a locked keychain, runs again; sendMessage confirms transport only. If
        // reachable, also sendMessage for speed; the epoch guard drops the duplicate.
                // sendMessage's error handler fires on a background queue;
                // hop to MainActor so we don't cross self's actor isolation.
