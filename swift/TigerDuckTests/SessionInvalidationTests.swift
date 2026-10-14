import Foundation
import Testing
@testable import TigerDuck

/// A sign-out empties the NTUST cookie jar, and a response of the departing account that lands
/// before its task is cancelled must not put that account's SSO session back
/// (https://github.com/tigerduck-app/tigerduck-app/issues/480).
struct SessionInvalidationTests {
    @Test func theJarIsEmptiedAgainOnceTheTasksAreCancelled() async throws {
        let jar = HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: "test.\(UUID().uuidString)")
        jar.cookieAcceptPolicy = .always
        // `getAllTasks` answers on the delegate queue; holding it lets the late cookie land first.
        let delegateQueue = OperationQueue()
        delegateQueue.isSuspended = true
        let session = URLSession(configuration: .ephemeral, delegate: nil, delegateQueue: delegateQueue)
        defer { session.invalidateAndCancel() }

        NTUSTSessionManager.cancelTasks(of: session, thenEmpty: jar)
        let late = try #require(HTTPCookie(properties: [
            .domain: "ssoam2.ntust.edu.tw", .path: "/", .name: "departing", .value: "1",
        ]))
        jar.setCookie(late)
        #expect(jar.cookies?.count == 1)
        delegateQueue.isSuspended = false

        try await waitUntil { jar.cookies?.isEmpty ?? true }
    }
}
