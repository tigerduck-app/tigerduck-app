import Foundation
import Testing
@testable import TigerDuckWatch_Watch_App

/// The watchOS simulator sends a session's requests past a `URLProtocol` stub, so these hand the
/// redirect to the delegate each POST goes out with instead of sending anything.
@MainActor
struct WatchLibraryRedirectTests {
    nonisolated final class Redirects: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [URLRequest?] = []
        private(set) var posted: [URLRequest] = []

        var followed: [URLRequest?] {
            lock.lock(); defer { lock.unlock() }
            return answers
        }

        func send(status: Int) -> WatchLibraryService.Send {
            { request, delegate in
                self.lock.lock()
                self.posted.append(request)
                self.lock.unlock()
                let url = try #require(request.url)
                let elsewhere = try #require(URL(string: "https://elsewhere.stub.invalid\(url.path)"))
                var resent = request
                resent.url = elsewhere
                let response = try #require(HTTPURLResponse(
                    url: url, statusCode: status, httpVersion: "HTTP/1.1",
                    headerFields: ["Location": elsewhere.absoluteString]
                ))
                let task = URLSession.shared.dataTask(with: request)
                delegate?.urlSession?(
                    URLSession.shared, task: task, willPerformHTTPRedirection: response, newRequest: resent
                ) { next in
                    self.lock.lock()
                    self.answers.append(next)
                    self.lock.unlock()
                }
                throw URLError(.cancelled)
            }
        }
    }

    @Test("the library sign-in stops at a 307 or a 308 rather than send the password on", arguments: [307, 308])
    func signInStopsAtARedirect(status: Int) async {
        let redirects = Redirects()
        await #expect(throws: (any Error).self) {
            try await WatchLibraryService.requestToken(
                username: "B00000000", password: "unused", send: redirects.send(status: status)
            )
        }
        #expect(redirects.posted.map(\.httpMethod) == ["POST"])
        #expect(redirects.followed.count == 1)
        #expect(redirects.followed.allSatisfy { $0 == nil })
    }

    @Test("a library code request stops at a 307 or a 308 rather than send the token on", arguments: [307, 308])
    func codeRequestStopsAtARedirect(status: Int) async {
        let redirects = Redirects()
        await #expect(throws: (any Error).self) {
            try await WatchLibraryService.requestQRCode(token: "library-token", send: redirects.send(status: status))
        }
        #expect(redirects.followed.count == 1)
        #expect(redirects.followed.allSatisfy { $0 == nil })
    }
}
