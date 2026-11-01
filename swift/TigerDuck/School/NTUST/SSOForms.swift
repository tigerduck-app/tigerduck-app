import Foundation
import os

enum SSOForms {
    /// Decode an HTML response respecting `Content-Type` charset. Older NTUST
    /// endpoints occasionally serve Big5 (or windows-1252 for ASCII-only
    /// pages); a hard UTF-8 decode would return nil on those and surface as
    /// `invalidResponse` for what is otherwise a recoverable response.
    static func decodeHTML(_ data: Data, response: URLResponse?) -> String? {
        let charset = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")?
            .lowercased()
        if let charset {
            if charset.contains("big5") {
                if let s = String(data: data, encoding: .init(rawValue:
                    CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))
                )) { return s }
            }
            if charset.contains("windows-1252") || charset.contains("iso-8859-1") {
                if let s = String(data: data, encoding: .isoLatin1) { return s }
            }
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        let big5 = String.Encoding(rawValue:
            CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
        return String(data: data, encoding: big5)
    }

    static func visit(_ url: URL, session: URLSession, isCurrent: @escaping @MainActor () -> Bool) async throws -> (String, URL) {
        let (data, response) = try await session.data(from: url)
        guard let httpResp = response as? HTTPURLResponse,
              let html = decodeHTML(data, response: httpResp) else {
            throw SSOLoginError.invalidResponse
        }
        return try await resolveOIDCBridgeForms(
            session: session, html: html, baseURL: httpResp.url ?? url, isCurrent: isCurrent
        )
    }

    static func resolveOIDCBridgeForms(
        session: URLSession,
        html: String,
        baseURL: URL,
        isCurrent: @escaping @MainActor () -> Bool,
        maxSteps: Int = 3
    ) async throws -> (String, URL) {
        var currentHTML = html
        var currentURL = baseURL

        for _ in 0..<maxSteps {
            if HTMLParser.isSSOLoginPage(html: currentHTML, url: currentURL) {
                return (currentHTML, currentURL)
            }

            guard let form = HTMLParser.findOIDCBridgeForm(currentHTML) else {
                return (currentHTML, currentURL)
            }

            let actionURL = resolveURL(form.action, base: currentURL)
            guard CredentialPost.isSchoolTarget(actionURL) else {
                AppLogger.auth.error(
                    "Sign-in bridge form action refused: \(CredentialPost.schemeLabel(of: actionURL), privacy: .public) \(actionURL.host ?? "", privacy: .private)"
                )
                throw SSOLoginError.invalidResponse
            }
            let (data, response) = try await postForm(
                session: session, url: actionURL, fields: form.inputs, isCurrent: isCurrent,
                delegate: CredentialPostDelegate()
            )
            if let resp = response as? HTTPURLResponse, (300..<400).contains(resp.statusCode) {
                throw SSOLoginError.invalidResponse
            }
            guard let newHTML = String(data: data, encoding: .utf8),
                  let resp = response as? HTTPURLResponse else {
                return (currentHTML, currentURL)
            }
            currentURL = resp.url ?? actionURL
            currentHTML = newHTML
        }

        return (currentHTML, currentURL)
    }

    static func postForm(
        session: URLSession,
        url: URL,
        fields: [(name: String, value: String)],
        isCurrent: @escaping @MainActor () -> Bool,
        delegate: (any URLSessionTaskDelegate & Sendable)? = nil
    ) async throws -> (Data, URLResponse) {
        try SSOLoginService.checkSignedIn(isCurrent)
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formBody(fields).utf8)

        return try await session.data(for: request, delegate: delegate)
    }

    static func formBody(_ fields: [(name: String, value: String)]) -> String {
        fields.map { "\(urlEncode($0.name))=\(urlEncode($0.value))" }.joined(separator: "&")
    }

    /// Form-encode a single name or value per
    /// `application/x-www-form-urlencoded` rules:
    /// percent-encode every byte outside RFC-3986 unreserved, then map
    /// space → `+`. This keeps passwords containing `+ & = / ; %` and
    /// CJK characters from being silently corrupted.
    private static let formAllowed: CharacterSet = {
        CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
    }()

    private static func urlEncode(_ string: String) -> String {
        guard let percentEncoded = string
            .addingPercentEncoding(withAllowedCharacters: formAllowed) else {
            assertionFailure("urlEncode failed for value of length \(string.count)")
            return ""
        }
        return percentEncoded.replacingOccurrences(of: "%20", with: "+")
    }

    static func resolveURL(_ path: String, base: URL) -> URL {
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return URL(string: path) ?? base
        }
        return URL(string: path, relativeTo: base)?.absoluteURL ?? base
    }

    static func replaceOrAppend(_ fields: inout [(String, String)], name: String, value: String) {
        if let idx = fields.firstIndex(where: { $0.0 == name }) {
            fields[idx] = (name, value)
        } else {
            fields.append((name, value))
        }
    }
}
