import Foundation
import WatchConnectivity
import os

/// Sends the pin document and acceptances to the Watch the way library credentials go: always
/// queued with `transferUserInfo`, which survives the Watch being away, and by `sendMessage` too
/// while it is reachable. `WatchTLSPinPayload.apply` on the Watch drops the duplicate.
@MainActor
final class TLSPinWatchBroadcaster {
    static let shared = TLSPinWatchBroadcaster()

    private let session: WatchSessionPushing
    private let engine: TLSPinEngine
    private let defaults: UserDefaults
    private let clock: () -> Date

    init(
        session: WatchSessionPushing? = nil,
        engine: TLSPinEngine = .shared,
        defaults: UserDefaults = .standard,
        clock: @escaping () -> Date = { Date() }
    ) {
        self.session = session ?? WCSession.default
        self.engine = engine
        self.defaults = defaults
        self.clock = clock
    }

    func userInfo() -> [String: Any]? {
        let payload = WatchTLSPinPayload(
            sentAtMs: WatchTLSPinPayload.nextSentAtMs(defaults: defaults, now: clock()),
            envelope: engine.storedEnvelope,
            acceptances: engine.acceptances
        )
        guard let json = try? payload.encodedJSON() else {
            AppLogger.tlsPins.error("TLS pin payload encode failed")
            return nil
        }
        return [
            WatchWireFormat.LibraryCredentialKey.kind: WatchWireFormat.UserInfoKind.tlsPins,
            WatchWireFormat.LibraryCredentialKey.payload: json,
        ]
    }

    func broadcast() {
        // Before activation both read false; the Watch's next sync request brings the pins then.
        guard WCSession.isSupported(), session.isPaired, session.isWatchAppInstalled,
              let userInfo = userInfo() else { return }
        _ = session.transferUserInfo(userInfo)
        if session.isReachable {
            session.sendMessage(userInfo, replyHandler: nil) { @Sendable error in
                AppLogger.tlsPins.error("TLS pin sendMessage failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }
}
