import Foundation
import SwiftSoup

nonisolated enum HTMLParser {

    struct FormData {
        let action: String
        let inputs: [(name: String, value: String)]
    }

    // MARK: - Public API

    /// Check if a response landed on the NTUST SSO login page.
    /// Host comparison is exact — a substring match would let
    /// `evil-ssoam2.ntust.edu.tw.attacker.com` impersonate the SSO host.
    static func isSSOLoginPage(html: String, url: URL) -> Bool {
        guard url.host == "ssoam2.ntust.edu.tw" else { return false }
        return looksLikeSSOLoginBody(html)
    }

    /// Body-only signature for the SSO login form, ignoring the URL.
    /// Use this when an upstream service (e.g. stuinfosys / score
    /// portal) returns 200 with the SSO form rendered inline instead
    /// of redirecting to ssoam2 — the URL-gated `isSSOLoginPage`
    /// would miss that case and the HTML parser would fall through
    /// to `.empty`.
    static func looksLikeSSOLoginBody(_ html: String) -> Bool {
        // Most pages checked are the service's own. One without either marker cannot match the
        // selectors below, whose attribute values match in any case, so only a hit is parsed.
        guard html.contains("loginForm") || html.range(of: "username", options: .caseInsensitive) != nil,
              let doc = try? SwiftSoup.parse(html) else { return false }

        return (try? doc.select("form#loginForm").first()) != nil ||
            ((try? doc.select("input[name=Username]").first()) != nil &&
                (try? doc.select("input[name=Password]").first()) != nil)
    }

    /// Check if a response landed on the NetIQ sign-in form of the other SSO host, ssoam. It
    /// submits through an invisible reCAPTCHA, so only a browser can sign in there.
    static func isNetIQLoginPage(html: String, url: URL) -> Bool {
        guard url.host == "ssoam.ntust.edu.tw", let doc = try? SwiftSoup.parse(html) else { return false }

        return (try? doc.select("form#IDPLogin").first()) != nil ||
            ((try? doc.select("input[name=Ecom_User_ID]").first()) != nil &&
                (try? doc.select("input[name=Ecom_Password]").first()) != nil)
    }

    /// Find a form by its id attribute and extract action + input fields
    static func findFormById(_ html: String, id: String) -> FormData? {
        guard let doc = try? SwiftSoup.parse(html),
              let forms = try? doc.select("form") else {
            return nil
        }

        for form in forms.array() {
            if (try? form.attr("id")) == id {
                return formData(from: form)
            }
        }

        return nil
    }

    /// Find an OIDC bridge form (has code/state/iss or SAMLResponse fields, excludes logout)
    static func findOIDCBridgeForm(_ html: String) -> FormData? {
        guard let doc = try? SwiftSoup.parse(html),
              let forms = try? doc.select("form") else {
            return nil
        }

        for form in forms.array() {
            guard let data = formData(from: form) else { continue }
            if data.action.lowercased().contains("logout") || data.action.isEmpty { continue }

            let names = Set(data.inputs.map(\.name))
            if names.contains("Username") || names.contains("Password") { continue }

            let isOIDC = (names.contains("code") && names.contains("state") && names.contains("iss")) ||
                         names.contains("id_token") ||
                         names.contains("SAMLResponse") ||
                         names.contains("RelayState") ||
                         names.contains("wresult") ||
                         names.contains("wctx")

            if isOIDC { return data }
        }

        return nil
    }

    /// The message a sign-in page shows for a rejected attempt, as plain text: the first
    /// element with one of the error classes that holds any text.
    static func loginErrorMessage(in html: String) -> String? {
        let ns = html as NSString
        let range = NSRange(location: 0, length: ns.length)
        for re in loginErrorRegexes {
            guard let match = re.firstMatch(in: html, options: [], range: range),
                  match.numberOfRanges >= 2 else {
                continue
            }
            let fragment = ns.substring(with: match.range(at: 1))
            let text = plainText(fromHTMLFragment: fragment)
            if !text.isEmpty {
                return text
            }
        }
        return nil
    }

    static func decodeHTMLEntities(_ s: String) -> String {
        var r = s
        r = r.replacingOccurrences(of: "&amp;", with: "&")
        r = r.replacingOccurrences(of: "&quot;", with: "\"")
        r = r.replacingOccurrences(of: "&apos;", with: "'")
        r = r.replacingOccurrences(of: "&lt;", with: "<")
        r = r.replacingOccurrences(of: "&gt;", with: ">")
        r = r.replacingOccurrences(of: "&#x2F;", with: "/")
        r = r.replacingOccurrences(of: "&#x27;", with: "'")
        r = r.replacingOccurrences(of: "&#39;", with: "'")
        return r
    }

    // MARK: - Helpers

    /// One precompiled regex per error-class name, lined up with `loginErrorClassNames`.
    private static let loginErrorClassNames: [String] = [
        "field-validation-error",
        "validation-summary-errors",
        "alert-danger",
        "text-danger",
    ]
    private static let loginErrorRegexes: [NSRegularExpression] = loginErrorClassNames.map { className in
        let pattern = #"<[^>]*class=["'][^"']*\b\#(className)\b[^"']*["'][^>]*>([\s\S]*?)</[^>]+>"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static func plainText(fromHTMLFragment fragment: String) -> String {
        let withoutTags = fragment.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return decodeHTMLEntities(withoutTags)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func formData(from form: Element) -> FormData? {
        let action = (try? form.attr("action")) ?? ""
        let inputElements: [Element] = (try? form.select("input").array()) ?? []
        let inputs: [(name: String, value: String)] = inputElements.compactMap { input -> (name: String, value: String)? in
            guard let name = try? input.attr("name"), !name.isEmpty else {
                return nil
            }

            let value = (try? input.attr("value")) ?? ""
            return (name, value)
        }

        return FormData(action: action, inputs: inputs)
    }
}
