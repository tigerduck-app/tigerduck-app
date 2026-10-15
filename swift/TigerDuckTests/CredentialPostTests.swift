import Foundation
import Testing
@testable import TigerDuck

/// `CredentialPost`'s rules on their own: which redirects of the sign-in form's POST it follows,
/// and as what.
struct CredentialPostTests {
    /// The sign-in form's POST, as URLSession would propose it again for a redirect.
    private static func post(to string: String) throws -> URLRequest {
        var request = URLRequest(url: try #require(URL(string: string)))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("34", forHTTPHeaderField: "Content-Length")
        request.httpBody = Data("Username=B00000000&Password=unused".utf8)
        return request
    }

    private static func redirect(_ status: Int) throws -> HTTPURLResponse {
        let url = try #require(URL(string: "https://ssoam2.ntust.edu.tw/account/login"))
        return try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil))
    }

    @Test("a 301, 302 or 303 is followed over HTTPS as a GET without the form", arguments: [301, 302, 303])
    func followsAsAGet(status: Int) throws {
        let proposed = try Self.post(to: "https://ssoam2.ntust.edu.tw/connect/authorize/callback")
        let response = try Self.redirect(status)
        let followed = try #require(CredentialPost.request(following: response, proposed: proposed))
        #expect(followed.url == proposed.url)
        #expect(followed.httpMethod == "GET")
        #expect(followed.httpBody == nil)
        #expect(followed.httpBodyStream == nil)
        #expect(followed.value(forHTTPHeaderField: "Content-Type") == nil)
        #expect(followed.value(forHTTPHeaderField: "Content-Length") == nil)
    }

    @Test("a 307 or a 308 is not followed, to ssoam2 either", arguments: [307, 308])
    func refusesARedirectThatResendsTheForm(status: Int) throws {
        let proposed = try Self.post(to: "https://ssoam2.ntust.edu.tw/account/login")
        let response = try Self.redirect(status)
        #expect(CredentialPost.request(following: response, proposed: proposed) == nil)
    }

    @Test("a redirect to plain HTTP is not followed", arguments: [301, 302, 303])
    func refusesPlainHTTP(status: Int) throws {
        let proposed = URLRequest(url: try #require(URL(string: "http://ssoam2.ntust.edu.tw/connect/authorize")))
        let response = try Self.redirect(status)
        #expect(CredentialPost.request(following: response, proposed: proposed) == nil)
    }
}
