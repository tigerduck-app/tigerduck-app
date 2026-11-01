import Foundation

nonisolated enum SchoolSessions {
    static func pinned(_ configuration: URLSessionConfiguration) -> URLSession {
        URLSession(configuration: configuration, delegate: TLSPinningDelegate.shared, delegateQueue: nil)
    }
}
