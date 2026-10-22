import Foundation

public struct WatchLibraryCredentialPayload: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case set
        case wipe
    }

    public let kind: Kind
    public let credEpoch: Int
    public let issuedAtMs: Int64
    public let username: String?
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
