import Foundation

enum HTMLParser {

    struct FormData {
        let action: String
        let inputs: [(name: String, value: String)]
    }

    // MARK: - Pre-compiled static regex patterns

    private static let allFormsRegex = try! NSRegularExpression(
        pattern: "<form[^>]*>(.*?)</form>",
        options: [.dotMatchesLineSeparators, .caseInsensitive]
    )

    private static let inputTagRegex = try! NSRegularExpression(
        pattern: "<input[^>]*>",
        options: [.caseInsensitive]
    )

    private static let formActionRegex = try! NSRegularExpression(
        pattern: "<form[^>]*action=\"([^\"]*)\"[^>]*>",
        options: .caseInsensitive
    )

    private static let nameAttrRegex = try! NSRegularExpression(
        pattern: "name=\"([^\"]*)\"",
        options: .caseInsensitive
    )

    private static let valueAttrRegex = try! NSRegularExpression(
        pattern: "value=\"([^\"]*)\"",
        options: .caseInsensitive
    )

    private static let valueAttrSQRegex = try! NSRegularExpression(
        pattern: "value='([^']*)'",
        options: .caseInsensitive
    )

    // MARK: - Public API

    /// Check if a response landed on the NTUST SSO login page
    static func isSSOLoginPage(html: String, url: URL) -> Bool {
        guard url.host?.contains("ssoam2.ntust.edu.tw") == true else { return false }
        return html.contains("id=\"loginForm\"") ||
               (html.contains("name=\"Username\"") && html.contains("name=\"Password\""))
    }

    /// Find a form by its id attribute and extract action + input fields
    static func findFormById(_ html: String, id: String) -> FormData? {
        let escaped = NSRegularExpression.escapedPattern(for: id)
        guard let regex = try? NSRegularExpression(
            pattern: "<form[^>]*id=\"\(escaped)\"[^>]*>(.*?)</form>",
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ),
        let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) else {
            return nil
        }

        let formRange = Range(match.range, in: html)!
        let formHTML = String(html[formRange])
        let action = firstCapture(formActionRegex, in: formHTML) ?? ""
        let inputs = extractInputFields(formHTML)
        return FormData(action: action, inputs: inputs)
    }

    /// Find an OIDC bridge form (has code/state/iss or SAMLResponse fields, excludes logout)
    static func findOIDCBridgeForm(_ html: String) -> FormData? {
        let matches = allFormsRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        for match in matches {
            guard let range = Range(match.range, in: html) else { continue }
            let formHTML = String(html[range])

            let action = firstCapture(formActionRegex, in: formHTML) ?? ""
            if action.lowercased().contains("logout") || action.isEmpty { continue }

            let inputs = extractInputFields(formHTML)
            if inputs.isEmpty { continue }

            let names = Set(inputs.map(\.name))
            if names.contains("Username") || names.contains("Password") { continue }

            let isOIDC = (names.contains("code") && names.contains("state") && names.contains("iss")) ||
                         names.contains("id_token") ||
                         names.contains("SAMLResponse") ||
                         names.contains("RelayState") ||
                         names.contains("wresult") ||
                         names.contains("wctx")

            if isOIDC { return FormData(action: action, inputs: inputs) }
        }
        return nil
    }

    /// Extract all <input> name/value pairs from HTML
    static func extractInputFields(_ html: String) -> [(name: String, value: String)] {
        var results: [(String, String)] = []
        let matches = inputTagRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        for match in matches {
            guard let range = Range(match.range, in: html) else { continue }
            let tag = String(html[range])
            guard let name = firstCapture(nameAttrRegex, in: tag), !name.isEmpty else { continue }
            let value = firstCapture(valueAttrRegex, in: tag) ?? firstCapture(valueAttrSQRegex, in: tag) ?? ""
            results.append((name, value))
        }
        return results
    }

    // MARK: - Helpers

    private static func firstCapture(_ regex: NSRegularExpression, in string: String) -> String? {
        guard let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              let range = Range(match.range(at: 1), in: string) else { return nil }
        return String(string[range])
    }
}
