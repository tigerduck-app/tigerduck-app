#if os(iOS)
import Foundation

/// How a mail connection gets to TLS.
///
/// The real school path is `implicitTLS` on both ports and nothing else: IMAP 993 and SMTP 465,
/// never 25, 143 or 587. The other two cases exist only so a DEBUG build can be pointed at a
/// server that speaks them; see `MailServerConfig.resolve(override:)`, which refuses to apply
/// either one to a pinned school host.
nonisolated enum MailTransportScheme: String, Codable, CaseIterable, Sendable {
    /// TLS from the first byte — what the school server uses on 993 and 465.
    case implicitTLS
    /// Plaintext greeting, then a required STARTTLS upgrade. Never negotiated as optional:
    /// SwiftMail maps this to `.startTLSRequired`, which fails the connection outright when
    /// the server does not advertise STARTTLS rather than continuing in the clear.
    case startTLS
    /// No TLS at all. Only ever reachable from the developer override.
    case plaintext

    /// Debug-only UI label. Not localized — the developer screens in this app are English.
    var title: String {
        switch self {
        case .implicitTLS: "Implicit TLS"
        case .startTLS: "STARTTLS"
        case .plaintext: "None (plaintext)"
        }
    }
}

/// The mail server School Mail talks to, resolved in one place.
///
/// Every read site goes through `effective`: `LiveMailClient`'s IMAP and SMTP connections, the
/// address the app writes in `From`, and the domain `MailWarnings` measures external and
/// mistyped recipients against. One answer decides all of them, so they never disagree. In a
/// Release build `effective` is `school`, with no branch that could return anything else: the
/// override's type, storage and screen are all inside `#if DEBUG` (`DevMailServerOverride.swift`).
nonisolated struct MailServerConfig: Equatable, Sendable {
    /// The domain of the user's own address — what `MailConstants.address(forStudentID:)`
    /// appends and what `MailWarnings.schoolMailDomain` measures typos against.
    var addressDomain: String
    /// The domain that counts as "inside", for the External badge. The school's mailbox domain
    /// is `mail.ntust.edu.tw` but a colleague writing from `ntust.edu.tw` or
    /// `mail.ee.ntust.edu.tw` is not an outside sender, so this is the organization's domain
    /// and `isOwnDomain` matches it and its subdomains.
    var organizationDomain: String
    var imapHost: String
    var imapPort: Int
    var imapScheme: MailTransportScheme
    var smtpHost: String
    var smtpPort: Int
    var smtpScheme: MailTransportScheme
    /// True only for a configuration a developer override produced. Read by the School Mail
    /// page's debug banner. Nothing about how mail is filed turns on it: `MailFolderProvisioner`
    /// creates Mail2000's role folders on whatever server is in force.
    var isOverridden: Bool

    /// The real school configuration: IMAP 993 and SMTP 465, both implicit TLS.
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

    /// The configuration in force right now.
    ///
    /// The `#else` arm is the whole of a Release build's resolution: one constant, no store to
    /// read, no override type in the binary.
    static var effective: MailServerConfig {
        #if DEBUG
        return DevMailServerOverride.shared.effectiveConfig
        #else
        return .school
        #endif
    }

    /// Whether `domain` (or a subdomain of it) is inside this configuration's organization.
    /// For `school` this is exactly the rule `MailWarnings.isSchoolDomain` has always applied:
    /// `ntust.edu.tw` and anything under it.
    func isOwnDomain(_ domain: String) -> Bool {
        let organization = organizationDomain.lowercased()
        guard !organization.isEmpty, !domain.isEmpty else { return false }
        return domain == organization || domain.hasSuffix("." + organization)
    }

    /// The transport `host` may use, given the one that was asked for. The override may not
    /// weaken the real school connection. `MailTLSVerifier` already covers certificates: it checks
    /// the system chain and hostname before the pin table, so an overridden host is unpinned but
    /// fully system-validated, and naming the school host brings its pins back. It cannot cover a
    /// transport with no certificate to check: `plaintext` never consults it, and `startTLS` sends
    /// the greeting and STARTTLS negotiation in the clear. So a pinned host keeps implicit TLS
    /// whatever the override asks. "Pinned" comes from the pin table, so the clamp follows it; a
    /// past-expiry set answers `.expired`, not `.notPinned`, so its host stays clamped.
    static func transportScheme(for host: String, requested: MailTransportScheme) -> MailTransportScheme {
        isPinnedHost(host) ? .implicitTLS : requested
    }

    static func isPinnedHost(_ host: String) -> Bool {
        TLSPinningDelegate.pinPolicy(forHost: host) != .notPinned
    }
}
#endif
