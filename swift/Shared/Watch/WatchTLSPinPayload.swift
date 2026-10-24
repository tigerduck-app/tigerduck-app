import Foundation

/// The phone's verified pin document and acceptances for the Watch, sent with `transferUserInfo`
/// rather than the schedule's application context, which is rebuilt whenever the schedule changes.
nonisolated struct WatchTLSPinPayload: Codable, Equatable, Sendable {
    private static let lastSentKey = "watchTLSPinsSentAtMs"

    let sentAtMs: Int64
    let envelope: Data?
    let acceptances: [TLSPinAcceptance]

    func encodedJSON() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }

    /// The phone's clock may run ahead; one further ahead than this would hold back every later
    /// payload's acceptances, so its acceptances are not applied.
    static let maxClockLead: TimeInterval = 24 * 60 * 60

    /// The Watch checks the envelope itself, and the engine orders envelopes by serial. The
    /// acceptances are the phone's whole list, applied only when newer than the last one and made
    /// under the Watch's own build. `sendMessage` and `transferUserInfo` both deliver each payload.
    @discardableResult
    static func apply(json: String, to engine: TLSPinEngine, defaults: UserDefaults, now: Date = Date()) -> Bool {
        guard let payload = try? JSONDecoder().decode(Self.self, from: Data(json.utf8)) else { return false }
        if let envelope = payload.envelope {
            engine.acceptDocument(envelope)
        }
        let latest = Int64(now.addingTimeInterval(maxClockLead).timeIntervalSince1970 * 1000)
        guard payload.sentAtMs > Int64(defaults.double(forKey: lastSentKey)), payload.sentAtMs <= latest else {
            return false
        }
        engine.replaceAcceptances(with: payload.acceptances)
        defaults.set(Double(payload.sentAtMs), forKey: lastSentKey)
        return true
    }
}
