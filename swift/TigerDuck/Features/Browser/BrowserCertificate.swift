import CryptoKit
import Foundation
import Security

/// What the certificate page shows of one certificate in a served chain. iOS has no public parser
/// for the subject and issuer fields (`SecCertificateCopyValues` is macOS only), so the names come
/// from a short walk of the DER; the validity dates come from Security.
nonisolated struct BrowserCertificate: Equatable, Identifiable, Sendable {
    nonisolated struct Name: Equatable, Sendable {
        var commonName: String?
        var organization: String?
    }

    let id: Int
    let subject: Name
    let issuer: Name
    let notBefore: Date?
    let notAfter: Date?
    let sha256: String

    var title: String { subject.commonName ?? subject.organization ?? sha256 }

    static func chain(of trust: SecTrust?) -> [BrowserCertificate] {
        guard let trust, let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else { return [] }
        return chain.enumerated().map { BrowserCertificate(id: $0.offset, $0.element) }
    }

    init(id: Int, _ certificate: SecCertificate) {
        let der = [UInt8](SecCertificateCopyData(certificate) as Data)
        let names = Self.names(in: der)
        self.id = id
        subject = names?.subject ?? Name(commonName: SecCertificateCopySubjectSummary(certificate) as String?)
        issuer = names?.issuer ?? Name()
        notBefore = SecCertificateCopyNotValidBeforeDate(certificate) as Date?
        notAfter = SecCertificateCopyNotValidAfterDate(certificate) as Date?
        sha256 = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// The issuer and subject of an X.509 certificate (RFC 5280 section 4.1): TBSCertificate's
    /// fields after its optional version, serial number and signature algorithm.
    static func names(in der: [UInt8]) -> (issuer: Name, subject: Name)? {
        var outer = DER(der[...])
        guard let certificate = outer.next() else { return nil }
        var certificateFields = DER(certificate.value)
        guard let tbs = certificateFields.next() else { return nil }
        var tbsFields = DER(tbs.value)
        var field = tbsFields.next()
        if field?.tag == 0xA0 { field = tbsFields.next() }
        _ = tbsFields.next()
        guard let issuer = tbsFields.next(), tbsFields.next() != nil, let subject = tbsFields.next() else { return nil }
        return (name(issuer.value), name(subject.value))
    }

    private static let commonNameOID: [UInt8] = [0x55, 0x04, 0x03]
    private static let organizationOID: [UInt8] = [0x55, 0x04, 0x0A]

    private static func name(_ value: ArraySlice<UInt8>) -> Name {
        var name = Name()
        var sets = DER(value)
        while let set = sets.next() {
            var attributes = DER(set.value)
            while let attribute = attributes.next() {
                var parts = DER(attribute.value)
                guard let oid = parts.next(), let text = parts.next() else { continue }
                if Array(oid.value) == commonNameOID { name.commonName = name.commonName ?? string(text) }
                if Array(oid.value) == organizationOID { name.organization = name.organization ?? string(text) }
            }
        }
        return name
    }

    private static func string(_ element: DER.Element) -> String? {
        switch element.tag {
        case 0x1E: String(bytes: element.value, encoding: .utf16BigEndian)
        case 0x0C, 0x13, 0x14, 0x16: String(decoding: element.value, as: UTF8.self)
        default: nil
        }
    }
}

/// Reads one DER element after another, definite lengths only.
private nonisolated struct DER {
    struct Element {
        let tag: UInt8
        let value: ArraySlice<UInt8>
    }

    private var bytes: ArraySlice<UInt8>

    init(_ bytes: ArraySlice<UInt8>) { self.bytes = bytes }

    mutating func next() -> Element? {
        guard let tag = bytes.popFirst(), let first = bytes.popFirst() else { return nil }
        var length = Int(first)
        if first & 0x80 != 0 {
            let count = Int(first & 0x7F)
            guard (1...4).contains(count), bytes.count >= count else { return nil }
            length = bytes.prefix(count).reduce(0) { $0 << 8 | Int($1) }
            bytes = bytes.dropFirst(count)
        }
        guard bytes.count >= length else { return nil }
        defer { bytes = bytes.dropFirst(length) }
        return Element(tag: tag, value: bytes.prefix(length))
    }
}
