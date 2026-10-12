import Foundation
import Testing
@testable import TigerDuck

/// Hand-made pages in the shape of the school's: the ssoam2 sign-in form, the OIDC and SAML
/// forms that carry a sign-in back to a service, a maintenance page and the NetIQ form on ssoam.
enum SSOPageFixtures {
    static let ssoam2LoginURL = URL(
        string: "https://ssoam2.ntust.edu.tw/account/login?ReturnUrl=%2Fconnect%2Fauthorize%2Fcallback"
    )!

    static let ssoam2Login = """
    <!DOCTYPE html>
    <html lang="zh-Hant">
    <head><meta charset="utf-8"><title>國立臺灣科技大學 單一登入</title></head>
    <body>
      <form id="logoutForm" action="/account/logout" method="post">
        <input name="__RequestVerificationToken" type="hidden" value="logout-token" />
      </form>
      <form id="loginForm" action="/account/login?ReturnUrl=%2Fconnect%2Fauthorize%2Fcallback" method="post">
        <input name="__RequestVerificationToken" type="hidden" value="anti&amp;forgery" />
        <input id="Username" name="Username" type="text" value="" />
        <input id="Password" name="Password" type="password" />
        <input name="captcha" type="hidden" value="" />
        <input name="ClientId" type="hidden" value="courseselection" />
        <input name="ReturnUrl" type="hidden" value="/connect/authorize/callback?client_id=courseselection" />
        <input type="submit" value="登入" />
      </form>
    </body>
    </html>
    """

    static let oidcBridge = """
    <html><head><title>Working...</title></head>
    <body onload="javascript:document.forms[0].submit()">
      <form method="post" action="https://courseselection.ntust.edu.tw/signin-oidc">
        <input type="hidden" name="code" value="auth-code" />
        <input type="hidden" name="scope" value="openid profile" />
        <input type="hidden" name="state" value="state-value" />
        <input type="hidden" name="session_state" value="session-state" />
        <input type="hidden" name="iss" value="https://ssoam2.ntust.edu.tw" />
        <noscript><button type="submit">Continue</button></noscript>
      </form>
    </body></html>
    """

    static let samlBridge = """
    <html><body>
      <form method="post" action="https://stuinfosys.ntust.edu.tw/Shibboleth.sso/SAML2/POST">
        <input type="hidden" name="SAMLResponse" value="PHNhbWw+" />
        <input type="hidden" name="RelayState" value="relay" />
      </form>
    </body></html>
    """

    static let maintenance = """
    <!DOCTYPE html>
    <html><head><title>系統維護中</title></head>
    <body>
      <h1>系統維護中</h1>
      <p>The system is under maintenance. Please come back later.</p>
    </body></html>
    """

    static let netIQLoginURL = URL(string: "https://ssoam.ntust.edu.tw/nidp/app/login?sid=0")!

    static let netIQLogin = """
    <html><head><title>NetIQ Access Manager</title></head>
    <body>
      <form id="IDPLogin" name="IDPLogin" method="POST" action="https://ssoam.ntust.edu.tw/nidp/app/login?sid=0">
        <input type="text" id="Ecom_User_ID" name="Ecom_User_ID" value="" />
        <input type="password" id="Ecom_Password" name="Ecom_Password" />
        <button class="g-recaptcha" data-sitekey="site-key" data-callback="onSubmit"
          data-bind="loginButton2">Login</button>
      </form>
    </body></html>
    """
}

@MainActor
struct HTMLParserTests {
    private typealias Pages = SSOPageFixtures

    @Test("the ssoam2 form counts as the sign-in page only on the ssoam2 host")
    func signInPageNeedsTheSSOHost() {
        #expect(HTMLParser.isSSOLoginPage(html: Pages.ssoam2Login, url: Pages.ssoam2LoginURL))
        let elsewhere = [
            "https://courseselection.ntust.edu.tw/",
            "https://ssoam2.ntust.edu.tw.example.com/account/login",
            "https://evil-ssoam2.ntust.edu.tw/account/login",
        ]
        for string in elsewhere {
            #expect(!HTMLParser.isSSOLoginPage(html: Pages.ssoam2Login, url: URL(string: string)!))
        }
    }

    @Test("only a sign-in form reads as the SSO body")
    func signInBody() {
        #expect(HTMLParser.looksLikeSSOLoginBody(Pages.ssoam2Login))
        let bareForm = #"<form action="/x"><input name="Username"><input name="Password"></form>"#
        #expect(HTMLParser.looksLikeSSOLoginBody(bareForm))

        let notSignIn = [
            Pages.oidcBridge, Pages.samlBridge, Pages.maintenance, Pages.netIQLogin,
            #"<form action="/x"><input name="Username"></form>"#,
            "",
        ]
        for html in notSignIn {
            #expect(!HTMLParser.looksLikeSSOLoginBody(html))
        }
        #expect(!HTMLParser.isSSOLoginPage(html: Pages.netIQLogin, url: Pages.netIQLoginURL))
    }

    @Test("field names in another case still read as the sign-in form, off the main actor too")
    func signInBodyInAnyCaseOffTheMainActor() async {
        let lowercase = #"<form action="/x"><input name="username"><input name="PASSWORD"></form>"#
        let found = await Task.detached {
            (HTMLParser.looksLikeSSOLoginBody(lowercase), HTMLParser.looksLikeSSOLoginBody(SSOPageFixtures.maintenance))
        }.value
        #expect(found == (true, false))
    }

    @Test("ssoam's NetIQ form is told apart from the ssoam2 form")
    func netIQSignInPage() {
        #expect(HTMLParser.isNetIQLoginPage(html: Pages.netIQLogin, url: Pages.netIQLoginURL))
        let fieldsOnly = #"<form action="/nidp/app/login"><input name="Ecom_User_ID"><input name="Ecom_Password"></form>"#
        #expect(HTMLParser.isNetIQLoginPage(html: fieldsOnly, url: Pages.netIQLoginURL))

        #expect(!HTMLParser.isNetIQLoginPage(html: Pages.netIQLogin, url: Pages.ssoam2LoginURL))
        #expect(!HTMLParser.isNetIQLoginPage(html: Pages.ssoam2Login, url: Pages.netIQLoginURL))
        #expect(!HTMLParser.isNetIQLoginPage(html: Pages.maintenance, url: Pages.netIQLoginURL))
        let userIdOnly = #"<form action="/nidp/app/login"><input name="Ecom_User_ID"></form>"#
        #expect(!HTMLParser.isNetIQLoginPage(html: userIdOnly, url: Pages.netIQLoginURL))
    }

    @Test("the sign-in form gives its action and every named input, entities decoded")
    func signInForm() throws {
        let form = try #require(HTMLParser.findFormById(Pages.ssoam2Login, id: "loginForm"))
        #expect(form.action == "/account/login?ReturnUrl=%2Fconnect%2Fauthorize%2Fcallback")
        #expect(form.inputs.map(\.name) == [
            "__RequestVerificationToken", "Username", "Password", "captcha", "ClientId", "ReturnUrl",
        ])
        #expect(form.inputs.first?.value == "anti&forgery")
        #expect(form.inputs.first(where: { $0.name == "Password" })?.value == "")
        #expect(HTMLParser.findFormById(Pages.ssoam2Login, id: "missing") == nil)
        #expect(HTMLParser.findFormById(Pages.maintenance, id: "loginForm") == nil)
    }

    @Test("the OIDC and SAML forms that carry a sign-in back are found")
    func bridgeForms() throws {
        let oidc = try #require(HTMLParser.findOIDCBridgeForm(Pages.oidcBridge))
        #expect(oidc.action == "https://courseselection.ntust.edu.tw/signin-oidc")
        #expect(oidc.inputs.map(\.name) == ["code", "scope", "state", "session_state", "iss"])
        #expect(oidc.inputs.first(where: { $0.name == "code" })?.value == "auth-code")

        let saml = try #require(HTMLParser.findOIDCBridgeForm(Pages.samlBridge))
        #expect(saml.action == "https://stuinfosys.ntust.edu.tw/Shibboleth.sso/SAML2/POST")
    }

    @Test("sign-in, sign-out and incomplete forms are not bridges")
    func notBridgeForms() {
        let notBridges = [
            Pages.ssoam2Login,
            Pages.maintenance,
            Pages.netIQLogin,
            #"<form action="/account/logout"><input name="code"><input name="state"><input name="iss"></form>"#,
            #"<form action=""><input name="id_token"></form>"#,
            #"<form action="/cb"><input name="code"><input name="state"></form>"#,
            #"<form action="/cb"><input name="id_token"><input name="Password"></form>"#,
        ]
        for html in notBridges {
            #expect(HTMLParser.findOIDCBridgeForm(html) == nil)
        }
    }

    @Test("input fields are read in order, unnamed ones skipped")
    func inputFields() {
        let html = #"<input name="a" value="1"><input value="unnamed"><input name="b"><input name="" value="x">"#
        let fields = HTMLParser.extractInputFields(html)
        #expect(fields.map(\.name) == ["a", "b"])
        #expect(fields.map(\.value) == ["1", ""])
    }
}
