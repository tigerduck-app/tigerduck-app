#if os(iOS)
import Foundation

nonisolated enum MailTransportScheme: String, Codable, CaseIterable, Sendable {
    case implicitTLS
    case startTLS
    case plaintext

    var title: String {
        switch self {
        case .implicitTLS: "Implicit TLS"
        case .startTLS: "STARTTLS"
        case .plaintext: "None (plaintext)"
        }
    }
}

nonisolated struct MailServerConfig: Equatable, Sendable {
    var addressDomain: String
    var organizationDomain: String
    var imapHost: String
    var imapPort: Int
    var imapScheme: MailTransportScheme
    var smtpHost: String
    var smtpPort: Int
    var smtpScheme: MailTransportScheme
    var isOverridden: Bool

    static let school = MailServerConfig(
        addressDomain: MailConstants.addressDomain,
        organizationDomain: "ntust.edu.tw",
        imapHost: MailConstants.host,
        imapPort: MailConstants.imapPort,
        imapScheme: .implicitTLS,
        smtpHost: MailConstants.host,
        smtpPort: MailConstants.smtpPort,
        smtpScheme: .implicitTLS,
        isOverridden: false
    )

    static var effective: MailServerConfig {
        #if DEBUG
        return DevMailServerOverride.shared.effectiveConfig
        #else
        return .school
        #endif
    }

    func isOwnDomain(_ domain: String) -> Bool {
        let organization = organizationDomain.lowercased()
        guard !organization.isEmpty, !domain.isEmpty else { return false }
        return domain == organization || domain.hasSuffix("." + organization)
    }

    static func transportScheme(for host: String, requested: MailTransportScheme) -> MailTransportScheme {
        isPinnedHost(host) ? .implicitTLS : requested
    }

    static func isPinnedHost(_ host: String) -> Bool {
        TLSPinningDelegate.pinPolicy(forHost: host) != .notPinned
    }
}
#endif
