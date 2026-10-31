#if os(iOS)
import Foundation

/// What a `MailClientError` says about the connection and the work under way, so the transport,
/// the page session, the checker and the index treat each failure alike.
nonisolated enum MailErrorClass: Equatable, Sendable {
    /// The network failed or the pins refused the certificate: the socket is of no further use.
    case connectionLost
    /// The server refused the password or was busy: every further command fails the same way,
    /// and NTUST counts each failed login towards a lockout.
    case accountRefused
    /// An answer that would not parse, which can be one mail's doing.
    case unreadableAnswer
    /// This request alone failed: a search the server refuses, a recreated folder, a send the
    /// server never confirmed.
    case requestOnly

    init(_ error: MailClientError) {
        switch error {
        case .unreachable, .certificateRejected: self = .connectionLost
        case .authenticationFailed, .serverBusy: self = .accountRefused
        case .protocolError: self = .unreadableAnswer
        case .searchUnsupported, .folderChanged, .sendUnconfirmed: self = .requestOnly
        }
    }

    /// Nil for an error that is not a `MailClientError`.
    init?(_ error: any Error) {
        guard let mailError = error as? MailClientError else { return nil }
        self.init(mailError)
    }

    /// The socket is closed, so the next command connects again.
    var closesConnection: Bool { self == .connectionLost }

    /// A run of commands over many mails or folders stops here instead of trying each one.
    var endsTheRun: Bool { self == .connectionLost || self == .accountRefused }

    /// The mail, not the server or the network, may be what failed.
    var blamesTheMail: Bool { self == .unreadableAnswer }
}
#endif
