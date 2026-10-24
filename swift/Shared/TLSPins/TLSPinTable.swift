import Foundation

/// A host group whose chains must contain one of `pins`: base64 SHA-256 of a SubjectPublicKeyInfo.
nonisolated struct TLSPinSet: Equatable, Sendable {
    nonisolated struct Domain: Equatable, Sendable {
        let name: String
        let includeSubdomains: Bool
    }

    let id: String
    let domains: [Domain]
    let pins: Set<String>
    let expiresAt: Date
}

/// The pins built into this build, the fallback when no signed document applies.
/// See docs/decisions/0025-remote-tls-pins.md.
nonisolated enum TLSPinTable {
    /// The serial of the first production document. A document must be newer to replace these sets.
    static let baselineSerial: Int64 = 0

    /// Ed25519 public keys that may sign the pin document, by `key_id`: base64 of the 32 raw bytes.
    /// `td-pins-2026a` signs on the server; `td-pins-2026b` is the standby kept offline.
    static let signingKeys: [String: String] = [
        "td-pins-2026a": "aTiq15fBtq+AuQt/+/DmJbRP7p0yge4psbaqrxf/sYc=",
        "td-pins-2026b": "bzAyG2WrY+A1T/E2D4IGH6YH+r7zOtC5cnuvd3j3WSo=",
    ]

    static let builtIn: [TLSPinSet] = [
        // TWCA Secure SSL CA and TWCA SSL CA, the two intermediates NTUST certificates come from,
        // and their roots, TWCA Global Root CA and TWCA CYBER Root CA.
        TLSPinSet(
            id: "ntust",
            domains: [.init(name: "ntust.edu.tw", includeSubdomains: true)],
            pins: [
                "9VZ7Yd685RTXsE6rL/puuMbnejYaXwaZasGL7c+Uolc=",
                "BxOmElsPeD54MBOb5h+TPNJnBlsAk6spRc/wLnko0cc=",
                "xES1tmzl1x4bXkDyc4XJXL/SSgW1b3DKwJkvD1DDN5w=",
                "BmALlMAxi7aWfwx3h8yKEDKhecTpXjxXYLMuKQ9/7Js=",
            ],
            expiresAt: date("2027-08-18")
        ),
        // Sectigo DV E36 and Sectigo's roots E46 and R46: each library renewal since 2022 changed
        // the issuer, and Sectigo now issues only under these two roots.
        TLSPinSet(
            id: "library",
            domains: [.init(name: "api.lib.ntust.edu.tw", includeSubdomains: true)],
            pins: [
                "ZSagvDzjltLkewXEBuDxIzpW/dpVw1Juvvmd0hhkzdY=",
                "sLVjNUaFYfW7n6EtgBeEpjOlcnBdNPMrZDRF36iwBdE=",
                "Douxi77vs4G+Ib/BogbTFymEYq0QSFXwSgVCaZcI09Q=",
            ],
            expiresAt: date("2027-05-04")
        ),
    ]

    private static func date(_ literal: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        guard let date = formatter.date(from: literal) else {
            fatalError("TLSPinTable: invalid date literal \(literal)")
        }
        return date
    }
}
