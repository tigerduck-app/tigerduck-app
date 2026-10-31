import Foundation

/// The sessions for school hosts that do not share `NTUSTSessionManager`'s cookie jar: each is
/// checked against the school's TLS pins.
nonisolated enum SchoolSessions {
    static func pinned(_ configuration: URLSessionConfiguration) -> URLSession {
        URLSession(configuration: configuration, delegate: TLSPinningDelegate.shared, delegateQueue: nil)
    }
}
