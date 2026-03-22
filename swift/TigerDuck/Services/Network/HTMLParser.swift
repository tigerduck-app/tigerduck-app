import Foundation

enum HTMLParser {

    struct FormData {
        let action: String
        let inputs: [(name: String, value: String)]
    }

    /// Check if a response landed on the NTUST SSO login page
    static func isSSOLoginPage(html: String, url: URL) -> Bool {
        guard url.host?.contains("ssoam2.ntust.edu.tw") == true else { return false }
        return html.contains("id=\"loginForm\"") ||
               (html.contains("name=\"Username\"") && html.contains("name=\"Password\""))
    }

    /// Find a form by its id attribute and extract action + input fields
    static func findFormById(_ html: String, id: String) -> FormData? {
        // Match <form ... id="<id>" ...>...</form>
        let pattern = "<form[^>]*id=\"\(NSRegularExpression.escapedPattern(for: id))\"[^>]*>(.*?)</form>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) else {
            return nil
        }

        let formRange = Range(match.range, in: html)!
        let formHTML = String(html[formRange])
        let action = extractAttribute(from: formHTML, tag: "form", attribute: "action") ?? ""
        let inputs = extractInputFields(formHTML)
        return FormData(action: action, inputs: inputs)
    }

    /// Find an OIDC bridge form (has code/state/iss or SAMLResponse fields, excludes logout)
    static func findOIDCBridgeForm(_ html: String) -> FormData? {
        let formPattern = "<form[^>]*>(.*?)</form>"
        guard let regex = try? NSRegularExpression(pattern: formPattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else {
            return nil
        }

        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        for match in matches {
            guard let range = Range(match.range, in: html) else { continue }
            let formHTML = String(html[range])

            let action = extractAttribute(from: formHTML, tag: "form", attribute: "action") ?? ""
            if action.lowercased().contains("logout") { continue }
            if action.isEmpty { continue }

            let inputs = extractInputFields(formHTML)
            if inputs.isEmpty { continue }

            let names = Set(inputs.map(\.name))

            // Skip interactive login forms
            if names.contains("Username") || names.contains("Password") { continue }

            // Accept OIDC / SAML bridge forms
            let isOIDC = (names.contains("code") && names.contains("state") && names.contains("iss")) ||
                         names.contains("id_token") ||
                         names.contains("SAMLResponse") ||
                         names.contains("RelayState") ||
                         names.contains("wresult") ||
                         names.contains("wctx")

            if isOIDC {
                return FormData(action: action, inputs: inputs)
            }
        }
        return nil
    }

    /// Extract all <input> name/value pairs from HTML
    static func extractInputFields(_ html: String) -> [(name: String, value: String)] {
        let pattern = "<input[^>]*>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        var results: [(String, String)] = []
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        for match in matches {
            guard let range = Range(match.range, in: html) else { continue }
            let tag = String(html[range])
            guard let name = extractTagAttribute(tag, "name"), !name.isEmpty else { continue }
            let value = extractTagAttribute(tag, "value") ?? ""
            results.append((name, value))
        }
        return results
    }

    /// Extract an attribute value from the first occurrence of a tag
    private static func extractAttribute(from html: String, tag: String, attribute: String) -> String? {
        let pattern = "<\(tag)[^>]*\(attribute)=\"([^\"]*)\"[^>]*>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[range])
    }

    /// Extract a single attribute from an HTML tag string
    private static func extractTagAttribute(_ tag: String, _ attribute: String) -> String? {
        // Try double quotes
        let dqPattern = "\(attribute)=\"([^\"]*)\""
        if let regex = try? NSRegularExpression(pattern: dqPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
           let range = Range(match.range(at: 1), in: tag) {
            return String(tag[range])
        }
        // Try single quotes
        let sqPattern = "\(attribute)='([^']*)'"
        if let regex = try? NSRegularExpression(pattern: sqPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
           let range = Range(match.range(at: 1), in: tag) {
            return String(tag[range])
        }
        return nil
    }
}
