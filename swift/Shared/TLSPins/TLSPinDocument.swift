import CryptoKit
import Foundation

/// The signed pin document from `https://api.tigerduck.app/.well-known/tigerduck/tls-pins.json`.
/// Only `verify` makes one, so every value has passed the signature check over `payload`.
nonisolated struct TLSPinDocument: Equatable, Sendable {
    nonisolated enum Failure: Error, Equatable {
        case malformed
        case unknownFormat
        case unknownKey
        case badSignature
    }

    static let format = 1

    let serial: Int64
    let expiresAt: Date
    let pinSets: [TLSPinSet]
    let promptRoots: Set<String>
    /// The signed bytes; documents with the same serial must carry the same ones.
    let payload: Data
    /// The envelope as received, which is what gets stored and forwarded to the watch.
    let envelope: Data

    /// Decodes `payload` once, checks the signature over those bytes, and only then parses them.
    static func verify(envelope: Data, keys: [String: Curve25519.Signing.PublicKey]) throws(Failure) -> TLSPinDocument {
        guard let outer = try? JSONDecoder().decode(Envelope.self, from: envelope) else { throw .malformed }
        guard outer.format == format else { throw .unknownFormat }
        guard let key = keys[outer.keyID] else { throw .unknownKey }
        guard let payload = Data(base64URL: outer.payload),
              let signature = Data(base64URL: outer.signature) else { throw .malformed }
        guard key.isValidSignature(signature, for: payload) else { throw .badSignature }
        guard let body = try? JSONDecoder().decode(Payload.self, from: payload) else { throw .malformed }
        guard body.format == format else { throw .unknownFormat }
        guard let expiresAt = parseDate(body.expiresAt) else { throw .malformed }
        var sets: [TLSPinSet] = []
        for set in body.pinSets {
            guard let setExpiry = parseDate(set.expiresAt) else { throw .malformed }
            sets.append(TLSPinSet(
                id: set.id,
                domains: set.domains.map { .init(name: $0.name.lowercased(), includeSubdomains: $0.includeSubdomains) },
                pins: Set(set.pins),
                expiresAt: setExpiry
            ))
        }
        return TLSPinDocument(
            serial: body.serial,
            expiresAt: expiresAt,
            pinSets: sets,
            promptRoots: Set(body.promptRoots),
            payload: payload,
            envelope: envelope
        )
    }

    static func keys(fromBase64 table: [String: String]) -> [String: Curve25519.Signing.PublicKey] {
        table.compactMapValues { encoded in
            Data(base64Encoded: encoded).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
        }
    }

    private static func parseDate(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    private struct Envelope: Decodable {
        let format: Int
        let keyID: String
        let payload: String
        let signature: String

        enum CodingKeys: String, CodingKey {
            case format, payload, signature
            case keyID = "key_id"
        }
    }

    private struct Payload: Decodable {
        let format: Int
        let serial: Int64
        let expiresAt: String
        let pinSets: [PinSet]
        let promptRoots: [String]

        enum CodingKeys: String, CodingKey {
            case format, serial
            case expiresAt = "expires_at"
            case pinSets = "pin_sets"
            case promptRoots = "prompt_roots"
        }
    }

    private struct PinSet: Decodable {
        let id: String
        let domains: [Domain]
        let pins: [String]
        let expiresAt: String

        enum CodingKeys: String, CodingKey {
            case id, domains, pins
            case expiresAt = "expires_at"
        }
    }

    private struct Domain: Decodable {
        let name: String
        let includeSubdomains: Bool

        enum CodingKeys: String, CodingKey {
            case name
            case includeSubdomains = "include_subdomains"
        }
    }
}

nonisolated extension Data {
    /// RFC 4648 section 5 base64url, with or without padding.
    init?(base64URL text: String) {
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        self.init(base64Encoded: standard)
    }
}
