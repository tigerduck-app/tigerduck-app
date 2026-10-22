import Foundation
import os

actor SettingsDocumentClient {
    private let baseURLProvider: @Sendable () -> URL
    private let session: URLSession
    private let authHeaderProvider: @Sendable () async -> String?
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Settings.API")

    init(
        baseURLProvider: @escaping @Sendable () -> URL = { PushServerConfig.resolveServerURL() },
        session: URLSession? = nil,
        authHeaderProvider: @escaping @Sendable () async -> String? = { nil }
    ) {
        self.baseURLProvider = baseURLProvider
        self.session = session ?? Self.defaultSession()
        self.authHeaderProvider = authHeaderProvider
    }

    func read(namespace: String) async throws -> (document: Data, revision: Int)? {
        var request = URLRequest(url: documentURL(for: namespace))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        await applyAuth(to: &request)

        let (data, statusCode) = try await perform(request)
        if statusCode == 404 {
            return nil
        }
        guard (200..<300).contains(statusCode) else {
            throw httpStatusError(statusCode, data: data, context: "GET \(namespace)")
    // MARK: - Public surface

    /// GET the current document for `namespace`.
    ///
    /// `nil` means the user has never written to this namespace — the
    /// backend 404s (`settings_docs.py:read_document`), and that is the
    /// normal state for a fresh account, not an error the caller needs to
    /// handle specially.
        }
        return try Self.parseDocumentEnvelope(data)
    }

    func write(namespace: String, document: Data, baseRevision: Int?) async throws -> SettingsWriteResult {
        let documentObject: Any
        do {
            documentObject = try JSONSerialization.jsonObject(with: document, options: [.fragmentsAllowed])
        } catch {
            throw PushAPIError.encodingFailed(error)
        }

        var envelope: [String: Any] = [
            "schema_version": 1,
            "document": documentObject,
        ]
    /// PUT `document` to `namespace`.
    ///
    /// `baseRevision: nil` asks the backend to create the document; it
    /// 409s if one already exists. A non-nil value does a compare-and-swap
    /// and 409s if the server's revision has moved on since. Either way a
    /// 409 is not thrown as an error — the response carries the winning
    /// document and revision (`settings_docs.py:_conflict_response`) so
    /// the caller can merge and retry instead of just failing.
        if let baseRevision {
            envelope["base_revision"] = baseRevision
        } else {
            envelope["base_revision"] = NSNull()
        }

        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: envelope)
        } catch {
            throw PushAPIError.encodingFailed(error)
        }

        var request = URLRequest(url: documentURL(for: namespace))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        await applyAuth(to: &request)

        let (data, statusCode) = try await perform(request)
        if statusCode == 409 {
            return try Self.parseConflict(data)
        }
        guard (200..<300).contains(statusCode) else {
            throw httpStatusError(statusCode, data: data, context: "PUT \(namespace)")
        }
        let json = try Self.jsonDictionary(data, context: "PUT response body is not a JSON object")
        guard let revision = json["revision"] as? Int else {
            throw Self.malformed("Missing 'revision' in response")
        }
        return .written(revision: revision)
    }

    private func documentURL(for namespace: String) -> URL {
        baseURLProvider().appendingPathComponent("settings/\(Self.percentEncoded(namespace))")
    }

    private static func jsonDictionary(_ data: Data, context: @autoclosure () -> String) throws -> [String: Any] {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw PushAPIError.decodingFailed(error)
        }
        guard let dictionary = parsed as? [String: Any] else {
            throw Self.malformed(context())
        }
        return dictionary
    }

    private static func malformed(_ message: String) -> PushAPIError {
        .decodingFailed(
            NSError(domain: "SettingsAPI", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: message])
        )
    }

    private static func documentData(_ object: Any) throws -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
        } catch {
            throw PushAPIError.decodingFailed(error)
        }
    }

    private static func parseDocumentEnvelope(_ data: Data) throws -> (document: Data, revision: Int) {
        let json = try jsonDictionary(data, context: "Response body is not a JSON object")
        guard
            let revision = json["revision"] as? Int,
            let documentObject = json["document"]
        else {
            throw Self.malformed("Missing 'document' or 'revision' in response")
        }
        return (try documentData(documentObject), revision)
    }

    private static func parseConflict(_ data: Data) throws -> SettingsWriteResult {
        let json = try jsonDictionary(data, context: "409 body is not a JSON object")
        guard
            let server = json["server"] as? [String: Any],
            let revision = server["revision"] as? Int,
            let documentObject = server["document"]
        else {
            throw Self.malformed("Missing 'server.document' or 'server.revision' in 409 body")
        }
        return .conflict(document: try documentData(documentObject), revision: revision)
    }

    private func applyAuth(to request: inout URLRequest) async {
        guard let header = await authHeaderProvider(), !header.isEmpty else { return }
        request.setValue(header, forHTTPHeaderField: "Authorization")
    }

    private func perform(_ request: URLRequest) async throws -> (data: Data, statusCode: Int) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PushAPIError.invalidResponse
        }
        await APIVersionGate.shared.note(statusCode: http.statusCode)
        return (data, http.statusCode)
    }

    private func httpStatusError(_ statusCode: Int, data: Data, context: String) -> PushAPIError {
        let snippet = String(data: data.prefix(512), encoding: .utf8) ?? ""
        logger.error("Settings.API \(statusCode, privacy: .public) \(context, privacy: .public): \(snippet, privacy: .private)")
        return .httpStatus(statusCode, body: snippet)
    }

    private static func defaultSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = [
            "User-Agent": "TigerDuck-iOS/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")"
        ]
        return URLSession(configuration: config)
    }

    private static func percentEncoded(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) else {
            assertionFailure("percentEncoded failed for value of length \(value.count)")
            return ""
        }
        return encoded
    }
}

nonisolated enum SettingsWriteResult: Equatable, Sendable {
    case written(revision: Int)
    case conflict(document: Data, revision: Int)
}
