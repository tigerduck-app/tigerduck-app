import Foundation
import os

///
actor SettingsDocumentClient {
    private let backend: BackendClient

    init(backend: BackendClient) {
        self.backend = backend
    }

    init(
        baseURLProvider: @escaping @Sendable () -> URL = { PushServerConfig.resolveServerURL() },
        session: URLSession? = nil,
        authHeaderProvider: @escaping @Sendable () async -> String? = { nil }
    ) {
        backend = BackendClient(
            baseURL: baseURLProvider, session: session ?? BackendClient.session, auth: .header(authHeaderProvider)
        )
    }

    /// nil when the backend 404s because the namespace was never written (`settings_docs.py:read_document`).
    func read(namespace: String) async throws -> (document: Data, revision: Int)? {
        var request = BackendRequest("GET", segments: ["settings", namespace])
        request.sendsWithoutSession = true
        request.accepting = [404]
        let response = try await backend.send(request)
        if response.status == 404 {
            // A backend without the route answers `not_found`, which says nothing of the document.
            guard BackendClient.errorCode(in: response.data) != "not_found" else {
                throw PushAPIError.httpStatus(404, body: String(decoding: response.data.prefix(512), as: UTF8.self))
            }
            return nil
        }
        return try Self.parseDocumentEnvelope(response.data)
    }

    /// A nil `baseRevision` creates the document, any other compare-and-swaps on it. A 409 is
    /// returned, not thrown: it carries the winning document and revision
    /// (`settings_docs.py:_conflict_response`) for the caller to merge and retry.
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

        var request = BackendRequest("PUT", segments: ["settings", namespace])
        request.sendsWithoutSession = true
        request.body = body
        request.accepting = [409]
        let response = try await backend.send(request)
        if response.status == 409 {
            return try Self.parseConflict(response.data)
        }
        let json = try Self.jsonDictionary(response.data, context: "PUT response body is not a JSON object")
        guard let revision = json["revision"] as? Int else {
            throw Self.malformed("Missing 'revision' in response")
        }
        return .written(revision: revision)
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
}

nonisolated enum SettingsWriteResult: Equatable, Sendable {
    case written(revision: Int)
    case conflict(document: Data, revision: Int)
}
