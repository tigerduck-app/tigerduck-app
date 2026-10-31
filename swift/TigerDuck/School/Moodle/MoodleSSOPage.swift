import Foundation

/// Reads the SSO login form, the OIDC bridge form and the token link out of the pages the Moodle
/// token harvest meets.
nonisolated enum MoodleSSOPage {
    struct SSOLoginFields {
        let action: String
        let antiforgery: String
        let clientId: String
        let returnUrl: String
        let uri: String
    }

    struct OIDCBridge {
        let action: URL
        let payload: [String: String]
    }

    private static let formBlockRegex = try! NSRegularExpression(
        pattern: "<form[^>]*>([\\s\\S]+?)</form>",
        options: [.caseInsensitive]
    )
    private static let formActionRegex = try! NSRegularExpression(
        pattern: "<form[^>]*action=[\"']([^\"']+)[\"']",
        options: [.caseInsensitive]
    )
    private static let inputNameRegex = try! NSRegularExpression(
        pattern: "<input[^>]*name=[\"']([^\"']+)[\"']",
        options: [.caseInsensitive]
    )
    private static let inputTagRegex = try! NSRegularExpression(
        pattern: "<input[^>]*>",
        options: [.caseInsensitive]
    )
    private static let inputNameAttrRegex = try! NSRegularExpression(
        pattern: "name=[\"']([^\"']+)[\"']",
        options: [.caseInsensitive]
    )
    private static let inputValueAttrRegex = try! NSRegularExpression(
        pattern: "value=[\"']([^\"']*)[\"']",
        options: [.caseInsensitive]
    )
    private static let moodleMobileTokenRegex = try! NSRegularExpression(
        pattern: #"["']moodlemobile://token=([A-Za-z0-9+/=_-]+)["']"#,
        options: []
    )

    static func parseSSOLoginFields(from html: String) -> SSOLoginFields {
        let ns = html as NSString
        let range = NSRange(location: 0, length: ns.length)
        var action = "/"
        var fields: [String: String] = [:]
        formBlockRegex.enumerateMatches(in: html, options: [], range: range) { match, _, stop in
            guard let m = match, m.numberOfRanges >= 2 else { return }
            let formFull = ns.substring(with: m.range)
            let formBody = ns.substring(with: m.range(at: 1))
            let names = extractInputNames(from: formBody)
            if names.contains("Username") && names.contains("Password") {
                action = extractFormAction(from: formFull) ?? "/"
                fields = extractInputPairs(from: formBody)
                stop.pointee = true
            }
        }
        return SSOLoginFields(
            action: action,
            antiforgery: fields["__RequestVerificationToken"] ?? "",
            clientId: fields["ClientId"] ?? "",
            returnUrl: fields["ReturnUrl"] ?? "",
            uri: fields["Uri"] ?? "",
        )
    }

    static func parseOIDCBridge(from html: String) -> OIDCBridge? {
        let ns = html as NSString
        let range = NSRange(location: 0, length: ns.length)
        var result: OIDCBridge?
        formBlockRegex.enumerateMatches(in: html, options: [], range: range) { match, _, stop in
            guard let m = match, m.numberOfRanges >= 2 else { return }
            let formFull = ns.substring(with: m.range)
            let formBody = ns.substring(with: m.range(at: 1))
            guard let action = extractFormAction(from: formFull) else {
                return
            }
            let payload = extractInputPairs(from: formBody)
            guard let resolvedActionURL = URL(string: action, relativeTo: MoodleTokenHarvest.ssoBaseURL)?.absoluteURL else { return }
            let isOidcAction = resolvedActionURL.host == "moodle2.ntust.edu.tw"
                && resolvedActionURL.path.hasPrefix("/auth/oidc")
            if isOidcAction,
                payload["code"] != nil
                && payload["state"] != nil
                && payload["iss"] != nil {
                result = OIDCBridge(action: resolvedActionURL, payload: payload)
                stop.pointee = true
            }
        }
        return result
    }

    static func extractFormAction(from formTag: String) -> String? {
        let ns = formTag as NSString
        guard let m = formActionRegex.firstMatch(
            in: formTag,
            options: [],
            range: NSRange(location: 0, length: ns.length),
        ), m.numberOfRanges >= 2 else {
            return nil
        }
        return ns.substring(with: m.range(at: 1))
    }

    static func extractInputNames(from html: String) -> Set<String> {
        let ns = html as NSString
        var names = Set<String>()
        inputNameRegex.enumerateMatches(
            in: html,
            options: [],
            range: NSRange(location: 0, length: ns.length),
        ) { match, _, _ in
            guard let m = match, m.numberOfRanges >= 2 else { return }
            names.insert(ns.substring(with: m.range(at: 1)))
        }
        return names
    }

    static func extractInputPairs(from html: String) -> [String: String] {
        let ns = html as NSString
        var out: [String: String] = [:]
        inputTagRegex.enumerateMatches(
            in: html,
            options: [],
            range: NSRange(location: 0, length: ns.length),
        ) { match, _, _ in
            guard let m = match else { return }
            let tag = ns.substring(with: m.range)
            let tagNs = tag as NSString
            let tagRange = NSRange(location: 0, length: tagNs.length)
            guard let nm = inputNameAttrRegex.firstMatch(in: tag, options: [], range: tagRange),
                  nm.numberOfRanges >= 2 else {
                return
            }
            let name = tagNs.substring(with: nm.range(at: 1))
            let value: String
            if let vm = inputValueAttrRegex.firstMatch(in: tag, options: [], range: tagRange),
               vm.numberOfRanges >= 2 {
                value = tagNs.substring(with: vm.range(at: 1))
            } else {
                value = ""
            }
            out[name] = decodeHTMLEntities(value)
        }
        return out
    }

    static func extractMoodleMobileToken(from html: String) -> String? {
        let ns = html as NSString
        guard let m = moodleMobileTokenRegex.firstMatch(
            in: html,
            options: [],
            range: NSRange(location: 0, length: ns.length),
        ), m.numberOfRanges >= 2 else {
            return nil
        }
        return ns.substring(with: m.range(at: 1))
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
}
