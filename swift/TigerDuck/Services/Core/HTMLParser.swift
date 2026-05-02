import Foundation
import SwiftSoup

enum HTMLParser {

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
        guard let doc = try? SwiftSoup.parse(html) else { return false }

        return (try? doc.select("form#loginForm").first()) != nil ||
            ((try? doc.select("input[name=Username]").first()) != nil &&
                (try? doc.select("input[name=Password]").first()) != nil)
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

    /// Extract all <input> name/value pairs from HTML
    static func extractInputFields(_ html: String) -> [(name: String, value: String)] {
        guard let doc = try? SwiftSoup.parse(html) else { return [] }

        let inputs: [Element] = (try? doc.select("input").array()) ?? []

        return inputs.compactMap { input -> (name: String, value: String)? in
            guard let name = try? input.attr("name"), !name.isEmpty else {
                return nil
            }

            let value = (try? input.attr("value")) ?? ""
            return (name, value)
        }
    }

    // MARK: - Helpers

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
