// Keeps unit tests off the school's servers and fails the test with the seam that tried. On watchOS
// a session sends a request even when a `URLProtocol` answers it, so the Watch's library seam asks
// the guard before its session instead. `nonisolated`: `URLSession` calls `startLoading()` off-main.
import Foundation
import ObjectiveC
import Testing
#if os(watchOS)
@testable import TigerDuckWatch_Watch_App
#else
@testable import TigerDuck
#endif

nonisolated final class SchoolNetworkGuard: URLProtocol {
    nonisolated struct Blocked: Equatable, Sendable {
        let seam: String
        let target: String

        var message: String {
            "A unit test reached the \(seam) (\(target)); give the test a fake for it."
        }
    }

    /// Seams a local run lets through, by name and comma-separated, for example
    /// `TEST_RUNNER_TIGERDUCK_REAL_SCHOOL_SEAMS="library sign-in" xcodebuild test ...`. CI sets none.
    static let optedIn: Set<String> = Set(
        (ProcessInfo.processInfo.environment["TIGERDUCK_REAL_SCHOOL_SEAMS"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    )

    private static let lock = NSLock()
    nonisolated(unsafe) private static var captured: [Blocked]?

    /// Puts the guard in front of every seam that reaches a school server: first in each session
    /// configuration, the School Mail client's stand-in, and the Watch's library seam.
    static func install() { _ = installed }

    private static let installed: Void = {
        #if os(watchOS)
        WatchLibraryService.testGuard = { try refuse($0) }
        #else
        URLProtocol.registerClass(SchoolNetworkGuard.self)
        exchange(#selector(getter: URLSessionConfiguration.default), #selector(URLSessionConfiguration.guardedDefault))
        exchange(#selector(getter: URLSessionConfiguration.ephemeral), #selector(URLSessionConfiguration.guardedEphemeral))
        #if os(iOS)
        if !optedIn.contains(RefusingMailClient.seam) {
            MailClientFactory.testStandIn = { RefusingMailClient() }
        }
        #endif
        #endif
    }()

    static var isInstalled: Bool {
        #if os(watchOS)
        WatchLibraryService.testGuard != nil
        #else
        URLSessionConfiguration.ephemeral.protocolClasses?.first == SchoolNetworkGuard.self
        #endif
    }

    private static func exchange(_ original: Selector, _ replacement: Selector) {
        guard let meta = object_getClass(URLSessionConfiguration.self),
              let originalMethod = class_getInstanceMethod(meta, original),
              let replacementMethod = class_getInstanceMethod(meta, replacement) else {
            fatalError("SchoolNetworkGuard: URLSessionConfiguration has no \(original)")
        }
        method_exchangeImplementations(originalMethod, replacementMethod)
    }

    /// A test that sets its own `protocolClasses` replaces the guard with its stub.
    static func guarding(_ config: URLSessionConfiguration) -> URLSessionConfiguration {
        let others = (config.protocolClasses ?? []).filter { $0 != SchoolNetworkGuard.self }
        config.protocolClasses = [SchoolNetworkGuard.self] + others
        return config
    }

    /// The seam a request to a school host comes from, told by its host and path; nil for any
    /// other host.
    static func seam(of request: URLRequest) -> String? {
        guard let url = request.url, let host = url.host?.lowercased(),
              TLSPinningDelegate.pinPolicy(forHost: host) != .notPinned else { return nil }
        let path = url.path
        switch host {
        case "moodle2.ntust.edu.tw":
            return path.hasSuffix("/launch.php") ? "Moodle token harvest" : "Moodle web service"
        case "api.lib.ntust.edu.tw":
            return path.hasSuffix("/passport/login") ? "library sign-in" : "library code request"
        case "ssoam2.ntust.edu.tw":
            return path == "/" && request.httpMethod == "GET" ? "SSO probe" : "SSO sign-in"
        case "courseselection.ntust.edu.tw" where path.isEmpty || path == "/":
            return "SSO sign-in"
        default:
            return "NTUST server \(host)"
        }
    }

    static func target(of request: URLRequest) -> String {
        "\(request.httpMethod ?? "GET") \(request.url?.host ?? "")\(request.url?.path ?? "")"
    }

    /// Throws for any request whose seam is not opted in, a school host's or not.
    static func refuse(_ request: URLRequest) throws {
        let seam = seam(of: request) ?? "school server"
        guard !optedIn.contains(seam) else { return }
        throw refusal(Blocked(seam: seam, target: target(of: request)))
    }

    /// Fails the running test with `blocked`, or hands it to ``capturing(_:)``, and returns the
    /// error the seam gets: an offline error, so no seam counts it as a refused password.
    static func refusal(_ blocked: Blocked) -> URLError {
        let isCaptured = lock.withLock {
            captured?.append(blocked)
            return captured != nil
        }
        if !isCaptured { Issue.record(Comment(rawValue: blocked.message)) }
        return URLError(.notConnectedToInternet, userInfo: [NSLocalizedDescriptionKey: blocked.message])
    }

    /// Runs `body` and returns what the guard stopped meanwhile instead of failing the test with
    /// it. For the guard's own tests, one at a time: a request another test sends meanwhile lands
    /// here too, and the caller's check on the list fails on it.
    static func capturing(_ body: () async throws -> Void) async rethrows -> [Blocked] {
        guard isInstalled else { fatalError("SchoolNetworkGuard is not installed; check the target's NSPrincipalClass") }
        lock.withLock { captured = [] }
        defer { lock.withLock { captured = nil } }
        try await body()
        return lock.withLock { captured ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let seam = seam(of: request) else { return false }
        return !optedIn.contains(seam)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let blocked = Blocked(seam: Self.seam(of: request) ?? "school server", target: Self.target(of: request))
        client?.urlProtocol(self, didFailWithError: Self.refusal(blocked))
    }

    override func stopLoading() {}
}

nonisolated extension URLSessionConfiguration {
    // `SchoolNetworkGuard.install()` swaps these with the system getters, so each calls the original.
    @objc fileprivate class func guardedDefault() -> URLSessionConfiguration {
        SchoolNetworkGuard.guarding(guardedDefault())
    }

    @objc fileprivate class func guardedEphemeral() -> URLSessionConfiguration {
        SchoolNetworkGuard.guarding(guardedEphemeral())
    }
}
