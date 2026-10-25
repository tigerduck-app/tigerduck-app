import CryptoKit
import Foundation
import Security

/// What the pin-mismatch prompt shows for one served certificate. `SecCertificate` has no public
/// issuer or validity accessor on every platform this builds for, so those come from the DER.
nonisolated struct TLSCertificateSummary: Equatable, Sendable {
    let name: String
    let issuer: String
    let issuerOrganization: String?
    let notBefore: Date?
    let notAfter: Date?
    let sha256Fingerprint: String

    init(der: Data) {
        let certificate = SecCertificateCreateWithData(nil, der as CFData)
        let fields = DERCertificateFields(der: [UInt8](der))
        name = certificate.flatMap { SecCertificateCopySubjectSummary($0) as String? }
            ?? fields?.subjectCommonName ?? ""
        issuer = fields?.issuerCommonName ?? fields?.issuerOrganization ?? ""
        issuerOrganization = fields?.issuerOrganization ?? fields?.issuerCommonName
        notBefore = fields?.notBefore
        notAfter = fields?.notAfter
        sha256Fingerprint = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

/// The few X.509 fields the summary needs, read from the tbsCertificate (RFC 5280 section 4.1).
private nonisolated struct DERCertificateFields {
    var issuerCommonName: String?
    var issuerOrganization: String?
    var subjectCommonName: String?
    var notBefore: Date?
    var notAfter: Date?

    init?(der: [UInt8]) {
        var outer = DERReader(der[...])
        guard let certificate = outer.read(tag: 0x30) else { return nil }
        var certificateReader = DERReader(certificate)
        guard let tbs = certificateReader.read(tag: 0x30) else { return nil }
        var reader = DERReader(tbs)
        _ = reader.read(tag: 0xA0)
        guard reader.read(tag: 0x02) != nil,
              reader.read(tag: 0x30) != nil,
              let issuer = reader.read(tag: 0x30),
              let validity = reader.read(tag: 0x30),
              let subject = reader.read(tag: 0x30) else { return nil }
        let issuerNames = Self.attributes(of: issuer)
        issuerCommonName = issuerNames[Self.commonName]
        issuerOrganization = issuerNames[Self.organization]
        subjectCommonName = Self.attributes(of: subject)[Self.commonName]
        var times = DERReader(validity)
        notBefore = times.readTime()
        notAfter = times.readTime()
    }

    private static let commonName: [UInt8] = [0x55, 0x04, 0x03]
    private static let organization: [UInt8] = [0x55, 0x04, 0x0A]

    /// The first value of each attribute type in a Name.
    private static func attributes(of name: ArraySlice<UInt8>) -> [[UInt8]: String] {
        var result: [[UInt8]: String] = [:]
        var rdns = DERReader(name)
        while let rdn = rdns.read(tag: 0x31) {
            var pairs = DERReader(rdn)
            while let pair = pairs.read(tag: 0x30) {
                var fields = DERReader(pair)
                guard let oid = fields.read(tag: 0x06), case let (tag, value)? = fields.readAny() else { continue }
                let key = Array(oid)
                if result[key] == nil, let text = decodeString(tag: tag, value) {
                    result[key] = text
                }
            }
        }
        return result
    }

    private static func decodeString(tag: UInt8, _ value: ArraySlice<UInt8>) -> String? {
        switch tag {
        case 0x0C, 0x13, 0x16: String(bytes: value, encoding: .utf8)
        case 0x14: String(bytes: value, encoding: .isoLatin1)
        case 0x1E: String(bytes: value, encoding: .utf16BigEndian)
        default: nil
        }
    }
}

private nonisolated struct DERReader {
    private var rest: ArraySlice<UInt8>

    init(_ bytes: ArraySlice<UInt8>) { rest = bytes }

    mutating func read(tag expected: UInt8) -> ArraySlice<UInt8>? {
        guard rest.first == expected, case let (_, content)? = readAny() else { return nil }
        return content
    }

    mutating func readAny() -> (UInt8, ArraySlice<UInt8>)? {
        var cursor = rest.startIndex
        guard cursor < rest.endIndex else { return nil }
        let tag = rest[cursor]
        cursor += 1
        guard cursor < rest.endIndex else { return nil }
        var length = Int(rest[cursor])
        cursor += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count > 0, count <= 4, cursor + count <= rest.endIndex else { return nil }
            length = rest[cursor..<cursor + count].reduce(0) { $0 << 8 | Int($1) }
            cursor += count
        }
        guard length <= rest.endIndex - cursor else { return nil }
        let content = rest[cursor..<cursor + length]
        rest = rest[(cursor + length)...]
        return (tag, content)
    }

    /// UTCTime (two-digit years 1950 to 2049) or GeneralizedTime, in UTC.
    mutating func readTime() -> Date? {
        guard case let (tag, value)? = readAny(), let text = String(bytes: value, encoding: .ascii) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        switch tag {
        case 0x17:
            formatter.dateFormat = "yyMMddHHmmss'Z'"
            formatter.twoDigitStartDate = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: formatter.timeZone, year: 1950).date
        case 0x18:
            formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        default:
            return nil
        }
        return formatter.date(from: text)
    }
}
