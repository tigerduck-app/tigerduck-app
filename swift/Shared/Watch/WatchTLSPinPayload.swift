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

    /// The Watch checks the envelope itself and keeps only acceptances made under its own build.
    /// A payload no newer than the last one applied is dropped, as `sendMessage` and
    /// `transferUserInfo` both deliver each one.
    @discardableResult
    static func apply(json: String, to engine: TLSPinEngine, defaults: UserDefaults) -> Bool {
        guard let payload = try? JSONDecoder().decode(Self.self, from: Data(json.utf8)),
              payload.sentAtMs > Int64(defaults.double(forKey: lastSentKey)) else { return false }
        if let envelope = payload.envelope {
            engine.acceptDocument(envelope)
        }
        engine.replaceAcceptances(with: payload.acceptances)
        defaults.set(Double(payload.sentAtMs), forKey: lastSentKey)
        return true
    }
}
