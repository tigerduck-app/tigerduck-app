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

    /// Body-only signature for the SSO login form, ignoring the URL.
    /// Use this when an upstream service (e.g. stuinfosys / score
    /// portal) returns 200 with the SSO form rendered inline instead
    /// of redirecting to ssoam2 — the URL-gated `isSSOLoginPage`
    /// would miss that case and the HTML parser would fall through
    /// to `.empty`.
    static func looksLikeSSOLoginBody(_ html: String) -> Bool {
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

    /// The text of `nodes` and of what they hold, without the elements `skipped` names, and with a
    /// space around each element `separates` names, which ends a word even where the HTML has no
    /// space. It walks a stack instead of recursing, so HTML of any depth fits on a thread's stack.
    static func visibleText(of nodes: [Node], skipping skipped: Set<String>, separating separates: (String) -> Bool) -> String {
        var text = ""
        var stack = nodes.reversed().map { (node: $0, closes: false) }
        while let (node, closes) = stack.popLast() {
            if closes {
                text += " "
            } else if let textNode = node as? TextNode {
                text += textNode.getWholeText()
            } else if let element = node as? Element {
                let tag = element.tagName().lowercased()
                if skipped.contains(tag) { continue }
                if separates(tag) {
                    text += " "
                    stack.append((node: element, closes: true))
                }
                stack += element.getChildNodes().reversed().map { (node: $0, closes: false) }
            }
        }
        return text
    }

    /// Replaces each element nested deeper than `AppConstants.maximumHTMLDepth` inside `root` with
    /// its `visibleText`. SwiftSoup finds a node's document by recursing once per ancestor on every
    /// change, so a tree must be this shallow before it is changed
    /// (https://github.com/tigerduck-app/tigerduck-app/issues/758).
    static func flattenPastTheDepthCap(
        _ root: Element, skipping skipped: Set<String>, separating separates: (String) -> Bool
    ) throws {
        var deep: [Element] = []
        var stack = root.children().array().map { (element: $0, depth: 1) }
        while let (element, depth) = stack.popLast() {
            if depth > AppConstants.maximumHTMLDepth {
                deep.append(element)
            } else {
                stack += element.children().array().map { (element: $0, depth: depth + 1) }
            }
        }
        for element in deep {
            let text = visibleText(of: [element], skipping: skipped, separating: separates)
            try element.replaceWith(TextNode(text, element.getBaseUri()))
        }
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
