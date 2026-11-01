import Foundation

nonisolated enum SchoolSessions {
    static let requestTimeout: TimeInterval = 15
    static let resourceTimeout: TimeInterval = 60

    static func pinned(_ configuration: URLSessionConfiguration) -> URLSession {
        URLSession(configuration: configuration, delegate: TLSPinningDelegate.shared, delegateQueue: nil)
    }
}
