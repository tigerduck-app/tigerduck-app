import NIO
import NIOSSL

/// Transport-security policy for IMAP and SMTP connections.
public enum MailTransportSecurity: Sendable, Equatable {
    /// Infer transport security from the server port, preserving SwiftMail's legacy defaults.
    case automatic

    /// Start the connection inside TLS from the first byte.
    case implicitTLS

    /// Require STARTTLS after the plaintext greeting or EHLO capability exchange.
    case startTLS

    /// Use plaintext transport without TLS.
    case plainText
}

/// A caller-supplied certificate check that **replaces** NIOSSL's verification entirely.
///
/// `verify` receives the peer's chain as DER-encoded certificates (leaf first) and the host
/// the connection was opened to, and returns `true` to accept the connection. It runs on the
/// connection's event loop, so it must not block for long. Verifiers compare by
/// `identifier`, which keeps ``MailCertificateVerificationPolicy`` `Equatable`.
///
/// - Important: this is not an extra check layered on top of platform trust. Installing it
///   overrides *all* of BoringSSL's verification, **hostname checking included**, and on Darwin
///   it also overwrites the Security.framework callback NIOSSL installs in
///   `NIOSSLContext.createConnection()` — `NIOSSLClientHandler.init` replaces it. `verify` is
///   therefore the whole evaluation: it must validate the chain against trusted roots and check
///   the certificate against `host` itself before applying whatever policy (pinning, say) it
///   was written for. A verifier that only compares public-key hashes accepts any chain from
///   any issuer for any name that happens to carry a pinned key.
///
///   `MailTLSConfiguration.makeClientConfiguration` still sets `.fullVerification` for this
///   policy, but only because NIOSSL skips a custom callback altogether when verification is
///   `.none`. It performs no validation of its own here.
public struct MailCertificateVerifier: Sendable {
    public let identifier: String
    public let verify: @Sendable (_ derChain: [[UInt8]], _ host: String) -> Bool

    public init(
        identifier: String,
        verify: @escaping @Sendable (_ derChain: [[UInt8]], _ host: String) -> Bool
    ) {
        self.identifier = identifier
        self.verify = verify
    }
}

extension MailCertificateVerifier: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.identifier == rhs.identifier }
}

/// Certificate-verification policy for TLS connections.
public enum MailCertificateVerificationPolicy: Sendable, Equatable {
    /// Validate the server certificate against trusted roots and the requested hostname.
    case fullVerification

    /// Do not validate the server certificate.
    ///
    /// Use only when the caller has explicitly chosen to trust an endpoint that presents a
    /// self-signed or otherwise locally untrusted certificate.
    case noVerification

    /// Hand the whole evaluation to a caller-supplied verifier instead of NIOSSL's default
    /// logic. The verifier owns chain *and* hostname validation — see
    /// ``MailCertificateVerifier``, which explains why a pin-only verifier here validates
    /// nothing.
    case custom(MailCertificateVerifier)
}

/// The lowest TLS protocol version a connection is allowed to negotiate.
///
/// Without this, connections inherit NIOSSL's `TLSConfiguration.makeClientConfiguration()`
/// default, which is TLS 1.0 — deprecated by
/// [RFC 8996](https://datatracker.ietf.org/doc/html/rfc8996) since March 2021.
///
/// Callers who know every server they talk to speaks TLS 1.3 can raise the floor and make
/// downgrades impossible regardless of what the server offers.
public enum MailTLSMinimumVersion: Sendable, Equatable {
    /// TLS 1.0. Deprecated by RFC 8996 — only for legacy servers that offer nothing newer.
    case tlsv1

    /// TLS 1.1. Deprecated by RFC 8996.
    case tlsv11

    /// TLS 1.2. The default, and the lowest version RFC 8996 still permits.
    case tlsv12

    /// TLS 1.3. The strongest floor; refuses to negotiate anything older.
    case tlsv13

    var nioTLSVersion: TLSVersion {
        switch self {
            case .tlsv1: return .tlsv1
            case .tlsv11: return .tlsv11
            case .tlsv12: return .tlsv12
            case .tlsv13: return .tlsv13
        }
    }
}

enum MailTLSConfiguration {
    /// - Note: `minimumTLSVersion` has no default for the same reason
    ///   `IMAPConnection.makeTLSHandler` has none: a default here turns "forgot to thread the
    ///   configured floor through" into "silently chose TLS 1.2", which is exactly the shape of
    ///   the implicit-TLS defect this change fixed. The *library-wide* default lives on the
    ///   public `IMAPServer`/`SMTPServer` initializers, where choosing it is visible.
    static func makeClientConfiguration(
        certificateVerificationPolicy: MailCertificateVerificationPolicy,
        minimumTLSVersion: MailTLSMinimumVersion
    ) -> TLSConfiguration {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.minimumTLSVersion = minimumTLSVersion.nioTLSVersion
        switch certificateVerificationPolicy {
            case .fullVerification, .custom:
                // `.custom` must keep verification on: NIOSSL skips a custom callback
                // entirely when `certificateVerification` is `.none`. That is the *only*
                // thing these two lines do for `.custom` — they do not add a layer of
                // validation underneath the callback. `NIOSSLCustomVerificationCallback`
                // overrides all of BoringSSL's verification, hostname checking included, and
                // on Darwin `NIOSSLClientHandler.init` overwrites the Security.framework
                // callback `NIOSSLContext.createConnection()` installed. So the verifier is
                // the whole evaluation, chain and hostname alike — see
                // `MailCertificateVerifier`.
                configuration.certificateVerification = .fullVerification
                configuration.trustRoots = .default
            case .noVerification:
                configuration.certificateVerification = .none
        }
        return configuration
    }

    static func serverHostnameForTLSHandler(host: String) -> String? {
        let normalizedHost = if host.hasPrefix("[") && host.hasSuffix("]") {
            String(host.dropFirst().dropLast())
        } else {
            host
        }

        if (try? SocketAddress(ipAddress: normalizedHost, port: 0)) != nil {
            return nil
        }
        return host
    }

    /// Builds the TLS handler for any policy, wiring the custom callback for `.custom`.
    static func makeClientHandler(
        host: String,
        certificateVerificationPolicy: MailCertificateVerificationPolicy,
        minimumTLSVersion: MailTLSMinimumVersion
    ) throws -> NIOSSLClientHandler {
        let configuration = makeClientConfiguration(
            certificateVerificationPolicy: certificateVerificationPolicy,
            minimumTLSVersion: minimumTLSVersion
        )
        let context = try NIOSSLContext(configuration: configuration)
        let serverHostname = serverHostnameForTLSHandler(host: host)
        guard case .custom(let verifier) = certificateVerificationPolicy else {
            return try NIOSSLClientHandler(context: context, serverHostname: serverHostname)
        }
        return try NIOSSLClientHandler(
            context: context,
            serverHostname: serverHostname,
            customVerificationCallback: customVerificationCallback(verifier: verifier, host: host)
        )
    }

    /// Converts the peer chain to DER and asks the verifier. A certificate that cannot be
    /// serialized fails the connection rather than being silently dropped from the chain.
    static func customVerificationCallback(
        verifier: MailCertificateVerifier,
        host: String
    ) -> NIOSSLCustomVerificationCallback {
        { certificates, promise in
            let derChain = certificates.compactMap { try? $0.toDERBytes() }
            let accepted = !derChain.isEmpty
                && derChain.count == certificates.count
                && verifier.verify(derChain, host)
            promise.succeed(accepted ? .certificateVerified : .failed)
        }
    }
}
