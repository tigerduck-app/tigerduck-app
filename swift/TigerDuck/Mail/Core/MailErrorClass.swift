#if os(iOS)
import Foundation

nonisolated enum MailErrorClass: Equatable, Sendable {
    case connectionLost
    /// NTUST counts each failed login towards a lockout.
    case accountRefused
    case unreadableAnswer
    case requestOnly

    init(_ error: MailClientError) {
        switch error {
        case .unreachable, .certificateRejected: self = .connectionLost
        case .authenticationFailed, .serverBusy: self = .accountRefused
        case .protocolError: self = .unreadableAnswer
        case .searchUnsupported, .folderChanged, .sendUnconfirmed: self = .requestOnly
        }
    }

    init?(_ error: any Error) {
        guard let mailError = error as? MailClientError else { return nil }
        self.init(mailError)
    }

    var closesConnection: Bool { self == .connectionLost }

    var endsTheRun: Bool { self == .connectionLost || self == .accountRefused }

    var blamesTheMail: Bool { self == .unreadableAnswer }
}
#endif
