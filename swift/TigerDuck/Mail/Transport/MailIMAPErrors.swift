#if os(iOS)
import Foundation
import SwiftMail

/// SwiftMail's IMAP and SMTP errors as the app's `MailClientError`.
nonisolated enum MailIMAPErrors {
    static func map(_ error: any Error) -> MailClientError {
        if let mailError = error as? MailClientError { return mailError }
        if let imapError = error as? IMAPError {
            switch imapError {
            case .loginFailed(let text): return classifyLoginFailure(text)
            case .authFailed, .unsupportedAuthMechanism: return .authenticationFailed
            case .timeout: return .unreachable
            case .connectionFailed(let reason): return classify(reason, fallback: .unreachable)
            default: return classify(String(describing: imapError), fallback: .protocolError(String(describing: imapError)))
            }
        }
        if let smtpError = error as? SMTPError {
            switch smtpError {
            case .authenticationFailed: return .authenticationFailed
            case .tlsFailed: return .certificateRejected
            case .connectionFailed(let reason): return classify(reason, fallback: .unreachable)
            default: return classify(String(describing: smtpError), fallback: .protocolError(String(describing: smtpError)))
            }
        }
        if let sendError = error as? SMTPSendError {
            if sendError.acceptance == .ambiguous { return .sendUnconfirmed }
            // `sendRawMessage` throws this for any failure after MAIL FROM (a rejected recipient,
            // a dropped connection mid-transaction, a timeout), the usual send failure. Most are
            // not network failures, so the fallback is `.protocolError`, not `.unreachable`.
            return classify(String(describing: sendError), fallback: .protocolError(String(describing: sendError)))
        }
        if isDecodeFailure(error) { return .protocolError(String(describing: error)) }
        let described = String(describing: error)
        return classify(described, fallback: isNetworkShaped(error) ? .unreachable : .protocolError(described))
    }

    /// A failure of the IMAP/SMTP response decoder or its parser, the server sent something
    /// this client cannot read.
    /// NIOIMAP surfaces these as `IMAPDecoderError` (wrapping a `ParserError`) straight from the
    /// channel and SwiftMail rethrows them untouched, but SwiftMail does not re-export NIOIMAP,
    /// so the type cannot be named here. Matched by name instead, the same way SwiftMail's own
    /// `shouldRecycleConnection` recognizes it.
    static func isDecodeFailure(_ error: any Error) -> Bool {
        let text = (String(describing: type(of: error)) + " " + String(describing: error)).lowercased()
        return text.contains("decodererror") || text.contains("parsererror")
    }

    static func isNetworkShaped(_ error: any Error) -> Bool {
        let domain = (error as NSError).domain
        if domain == NSURLErrorDomain || domain == NSPOSIXErrorDomain { return true }
        let name = String(describing: type(of: error)).lowercased()
        return name.contains("connectionerror") || name.contains("channelerror") || name.contains("ioerror")
    }

    /// `.commandFailed`/`.commandNotSupported` from a server-issued SEARCH means the server
    /// refused the query outright (Mail2000 can reject search keys it doesn't support); every
    /// other `IMAPError` isn't search-specific and maps through the general `map(_:)`.
    static func mapSearchError(_ error: IMAPError) -> MailClientError {
        switch error {
        case .commandFailed, .commandNotSupported: .searchUnsupported
        default: map(error)
        }
    }

    /// SwiftMail turns every tagged NO/BAD reply to LOGIN into `IMAPError.loginFailed(text)`
    /// (`LoginHandler.handleTaggedErrorResponse`), with no distinction between a wrong password
    /// and the server temporarily refusing new sessions, a LOGIN NO for "too many connections"
    /// looks identical in shape to a rejected password. Only the RFC 5530 response codes a
    /// server actually uses to say "temporarily unavailable, try later" (`[UNAVAILABLE]`,
    /// `[LIMIT]`, `[INUSE]`) or the literal phrase Mail2000 sends for its connection cap count as
    /// `.serverBusy`; every other LOGIN failure, including generic phrasing like "try again"
    /// that a wrong-password reply could just as easily contain, stays `.authenticationFailed`.
    static func classifyLoginFailure(_ text: String) -> MailClientError {
        let lowered = text.lowercased()
        let busyResponseCodes = ["[unavailable]", "[limit]", "[inuse]"]
        if busyResponseCodes.contains(where: lowered.contains) { return .serverBusy }
        if lowered.contains("too many connections") { return .serverBusy }
        return .authenticationFailed
    }

    /// TLS certificate/verification failures surface as NIOSSL handshake errors that mention
    /// the certificate; a busy server as NO/BYE text. A handshake failure that does *not*
    /// mention a certificate (e.g. a protocol-version alert) is a transport problem, not a
    /// trust one, and falls through to whatever `fallback` the caller passed, `.unreachable`
    /// for a raw connection failure, `.protocolError(...)` for an otherwise-unrecognized
    /// `IMAPError`/`SMTPError`/`SMTPSendError`, rather than being misreported as
    /// `.certificateRejected`.
    static func classify(_ text: String, fallback: MailClientError) -> MailClientError {
        let lowered = text.lowercased()
        if lowered.contains("certificate") { return .certificateRejected }
        if lowered.contains("too many") || lowered.contains("busy") || lowered.contains("try again later") { return .serverBusy }
        if lowered.contains("authenticationfailed") || lowered.contains("login failed") { return .authenticationFailed }
        return fallback
    }
}
#endif
