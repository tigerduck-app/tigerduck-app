import Foundation
import Testing
@testable import TigerDuck

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
