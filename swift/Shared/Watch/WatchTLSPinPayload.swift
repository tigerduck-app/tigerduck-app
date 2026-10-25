import Foundation

/// The phone's verified pin document and acceptances for the Watch, sent with `transferUserInfo`
/// rather than the schedule's application context, which is rebuilt whenever the schedule changes.
nonisolated struct WatchTLSPinPayload: Codable, Equatable, Sendable {
    private static let lastSentKey = "watchTLSPinsSentAtMs"
    private static let lastStampKey = "watchTLSPinsLastStampMs"

    let sentAtMs: Int64
    let envelope: Data?
    let acceptances: [TLSPinAcceptance]

    func encodedJSON() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }

    /// The phone's clock may run ahead; one further ahead than this would hold back every later
    /// payload's acceptances, so its acceptances are not applied.
    static let maxClockLead: TimeInterval = 24 * 60 * 60

    /// The phone's stamp for its next payload: its clock, or one past its last stamp when the clock
    /// was set back after running ahead, so the Watch still orders later payloads after the ones it
    /// took. A last stamp more than `maxClockLead` ahead of the clock is one the Watch refused, so
    /// the clock is used again rather than held back by it.
    static func nextSentAtMs(defaults: UserDefaults, now: Date) -> Int64 {
        let clock = Int64(now.timeIntervalSince1970 * 1000)
        let last = Int64(defaults.double(forKey: lastStampKey))
        let stamp = last - clock > Int64(maxClockLead * 1000) ? clock : max(clock, last + 1)
        defaults.set(Double(stamp), forKey: lastStampKey)
        return stamp
    }

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
