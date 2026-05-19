import Foundation

/// One credential push from the phone to the watch. Delivered via
/// `WCSession.transferUserInfo` (FIFO, guaranteed) — NOT bundled into
/// the schedule `applicationContext` because that channel is
/// latest-only and a stale `set` overwriting a fresh `wipe` would
/// strand credentials on the watch after a phone logout.
public struct WatchLibraryCredentialPayload: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case set
        case wipe
    }

    public let kind: Kind
    /// Monotonically incrementing per phone install. The watch rejects
    /// payloads with `credEpoch <= storedEpoch`, which makes the channel
    /// idempotent and tolerant of out-of-order WC delivery.
    public let credEpoch: Int
    /// When the phone composed this payload. Drives the watch's 7-day
    /// TTL purge — independent of WC delivery time so a payload that
    /// queued for a week still expires correctly.
    public let issuedAtMs: Int64
    /// Only populated when `kind == .set`.
    public let username: String?
    /// Only populated when `kind == .set`.
    public let password: String?

    public init(
        kind: Kind,
        credEpoch: Int,
        issuedAtMs: Int64,
        username: String? = nil,
        password: String? = nil
    ) {
        assert(
            kind == .set || (username == nil && password == nil),
            ".wipe payloads must not carry credentials"
        )
        self.kind = kind
        self.credEpoch = credEpoch
        self.issuedAtMs = issuedAtMs
        self.username = username
        self.password = password
    }

    /// JSON-encode for embedding in the WC userInfo dictionary as a
    /// string value. Mirrors `clockOverrideJSON` packing in the
    /// schedule snapshot — keeps the wire format plist-clean and the
    /// receiver decoding path-independent of this type.
    public func encodedJSON() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let s = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: [],
                    debugDescription: "JSON data not UTF-8 decodable"
                )
            )
        }
        return s
    }

    public static func decode(json: String) throws -> WatchLibraryCredentialPayload {
        guard let data = json.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "payload string is not UTF-8"
                )
            )
        }
        return try JSONDecoder().decode(WatchLibraryCredentialPayload.self, from: data)
    }
}
