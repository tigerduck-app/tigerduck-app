import Foundation
import Testing
@testable import TigerDuck

/// `CredentialPost`'s rules on their own: where the sign-in form may post the password, and which
/// redirects of that POST it follows, and as what.
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

    @Test("the form posts only to ssoam2 over HTTPS, the host in any case")
    func signInTarget() throws {
        let signInHost = [
            "https://ssoam2.ntust.edu.tw/account/login?ReturnUrl=%2F",
            "HTTPS://ssoam2.ntust.edu.tw/",
            "https://SSOAM2.NTUST.EDU.TW/account/login",
        ]
        for string in signInHost {
            let url = try #require(URL(string: string))
            #expect(CredentialPost.isSignInTarget(url), "\(string)")
        }
        let elsewhere = [
            "http://ssoam2.ntust.edu.tw/account/login",
            "https://elsewhere.stub.invalid/account/login",
            "https://ssoam2.ntust.edu.tw.elsewhere.stub.invalid/account/login",
            "https://ssoam2.ntust.edu.tw@elsewhere.stub.invalid/account/login",
            "https://ssoam.ntust.edu.tw/nidp/app/login",
            "https://ssoam2.ntust.edu.tw./",
        ]
        for string in elsewhere {
            let url = try #require(URL(string: string))
            #expect(!CredentialPost.isSignInTarget(url), "\(string)")
        }
    }

    @Test("a form passing the sign-in on posts only to the school's hosts over HTTPS")
    func schoolTarget() throws {
        let school = [
            "https://courseselection.ntust.edu.tw/signin-oidc",
            "https://stuinfosys.ntust.edu.tw/Shibboleth.sso/SAML2/POST",
            "HTTPS://Moodle2.NTUST.EDU.TW/auth/oidc/",
            "https://ntust.edu.tw/",
        ]
        for string in school {
            let url = try #require(URL(string: string))
            #expect(CredentialPost.isSchoolTarget(url), "\(string)")
        }
        let elsewhere = [
            "http://courseselection.ntust.edu.tw/signin-oidc",
            "https://elsewhere.stub.invalid/signin-oidc",
            "https://courseselection.ntust.edu.tw.elsewhere.stub.invalid/signin-oidc",
            "https://courseselection.ntust.edu.tw@elsewhere.stub.invalid/signin-oidc",
            "https://elsewherentust.edu.tw/signin-oidc",
            "https://courseselection.ntust.edu.tw./signin-oidc",
        ]
        for string in elsewhere {
            let url = try #require(URL(string: string))
            #expect(!CredentialPost.isSchoolTarget(url), "\(string)")
        }
    }

    @Test("a form action's scheme reaches the log as http, https or other")
    func schemeLabel() throws {
        let actions = ["https://elsewhere.stub.invalid/", "HTTP://elsewhere.stub.invalid/", "javascript:void(0)", "ftp://elsewhere.stub.invalid/"]
        let labels = try actions.map { CredentialPost.schemeLabel(of: try #require(URL(string: $0))) }
        #expect(labels == ["https", "http", "other", "other"])
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
