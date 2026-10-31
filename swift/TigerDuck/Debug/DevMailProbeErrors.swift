#if DEBUG && os(iOS)
import Foundation
import Network
import Security

/// Names the errors and TLS versions the probe reports.
nonisolated enum DevMailProbeErrors {
    /// the two cases worth *reporting* most loudly — 1.0 and 1.1 — are the two the SDK deprecates
    /// naming, and a diagnostic that cannot say "this server negotiated TLS 1.0" is no use. The
    /// numbers are the TLS `ProtocolVersion` values themselves and do not move.
    static func tlsVersionName(_ rawVersion: UInt16) -> String {
        switch rawVersion {
        case 0x0301: "TLS 1.0"
        case 0x0302: "TLS 1.1"
        case 0x0303: "TLS 1.2"
        case 0x0304: "TLS 1.3"
        case 0xfeff: "DTLS 1.0"
        case 0xfefd: "DTLS 1.2"
        default: "TLS 0x\(String(rawVersion, radix: 16))"
        }
    }

    static func describe(_ error: any Error) -> String {
        if let network = error as? NWError { return describe(network) }
        let bridged = error as NSError
        let described = "\(type(of: error)): \(String(describing: error))"
        guard carriesReadableCode(domain: bridged.domain) else { return described }
        return "\(described) [\(bridged.domain) \(bridged.code)]"
    }

    static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code):
            return "NWError.posix(\(code)) — errno \(code.rawValue), \(String(cString: strerror(code.rawValue)))"
        case .dns(let code):
            return "NWError.dns(\(code)) — \(dnsErrorName(code))"
        case .tls(let status):
            return "NWError.tls(\(status)) — \(securityMessage(status))"
        default:
            return String(describing: error)
        }
    }

    /// enum bridges to a domain that is its own mangled type name and a code that is its case
    /// index, which says nothing the description does not.
    static func carriesReadableCode(domain: String) -> Bool {
        [NSURLErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain, "kCFErrorDomainCFNetwork"].contains(domain)
    }

    static func dnsErrorName(_ code: DNSServiceErrorType) -> String {
        switch code {
        case -65537: "kDNSServiceErr_Unknown"
        case -65538: "kDNSServiceErr_NoSuchName"
        case -65540: "kDNSServiceErr_BadParam"
        case -65544: "kDNSServiceErr_Unsupported"
        case -65553: "kDNSServiceErr_Refused"
        case -65554: "kDNSServiceErr_NoSuchRecord — the name exists but has no address record"
        case -65562: "kDNSServiceErr_Transient"
        case -65563: "kDNSServiceErr_ServiceNotRunning"
        case -65566: "kDNSServiceErr_NoRouter"
        case -65568: "kDNSServiceErr_Timeout"
        default: "unnamed DNSServiceErrorType"
        }
    }

    static func securityMessage(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "no message for this OSStatus"
    }
}
#endif
