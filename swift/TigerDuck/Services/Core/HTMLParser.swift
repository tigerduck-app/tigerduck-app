import Foundation
import SwiftSoup

nonisolated enum HTMLParser {

    struct FormData {
        let action: String
        let inputs: [(name: String, value: String)]
    }

    static func isSSOLoginPage(html: String, url: URL) -> Bool {
        guard url.host == "ssoam2.ntust.edu.tw" else { return false }
        return looksLikeSSOLoginBody(html)
    }

    static func looksLikeSSOLoginBody(_ html: String) -> Bool {
        guard html.contains("loginForm") || html.range(of: "username", options: .caseInsensitive) != nil,
              let doc = try? SwiftSoup.parse(html) else { return false }

        return (try? doc.select("form#loginForm").first()) != nil ||
            ((try? doc.select("input[name=Username]").first()) != nil &&
                (try? doc.select("input[name=Password]").first()) != nil)
    }

    static func isNetIQLoginPage(html: String, url: URL) -> Bool {
        guard url.host == "ssoam.ntust.edu.tw", let doc = try? SwiftSoup.parse(html) else { return false }

        return (try? doc.select("form#IDPLogin").first()) != nil ||
            ((try? doc.select("input[name=Ecom_User_ID]").first()) != nil &&
                (try? doc.select("input[name=Ecom_Password]").first()) != nil)
    }

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

    static func loginErrorMessage(in html: String) -> String? {
        guard let doc = try? SwiftSoup.parse(html) else { return nil }
        for className in loginErrorClassNames {
            for element in (try? doc.getElementsByClass(className).array()) ?? [] {
                if let text = try? element.text(), !text.isEmpty { return text }
            }
        }
        return nil
    }

    private static let loginErrorClassNames = [
        "field-validation-error",
        "validation-summary-errors",
        "alert-danger",
        "text-danger",
    ]

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
