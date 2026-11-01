import Foundation
import os

/// Reads and writes the settings documents of the sign-in it was made for.
actor SettingsDocumentClient {
    private let backend: BackendClient
    private let signIn: SignIn

    init(
        baseURLProvider: @escaping @Sendable () -> URL = { PushServerConfig.resolveServerURL() },
        session: URLSession? = nil,
        auth: BackendAuth,
        for signIn: SignIn
    ) {
        backend = BackendClient(baseURL: baseURLProvider, session: session ?? BackendClient.session, auth: auth)
        self.signIn = signIn
    }

    func read(namespace: String) async throws -> SettingsDocument {
        var request = BackendRequest("GET", segments: ["settings", namespace]).sent(for: signIn)
        request.sendsWithoutSession = true
        request.accepting = [404]
        let response = try await backend.send(request)
        if response.status == 404 {
            guard BackendClient.errorCode(in: response.data) == "settings_document_not_found" else {
                throw PushAPIError.httpStatus(404, body: String(decoding: response.data.prefix(512), as: UTF8.self))
            }
            return .neverWritten
        }
        let (document, revision) = try Self.parseDocumentEnvelope(response.data)
        return .stored(document: document, revision: revision)
    }

    func write(namespace: String, document: Data, mode: SettingsWriteMode) async throws -> SettingsWriteResult {
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
        switch mode {
        case .create: envelope["base_revision"] = NSNull()
        case .replace(let revision): envelope["base_revision"] = revision
        }

        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: envelope)
        } catch {
            throw PushAPIError.encodingFailed(error)
        }

        var request = BackendRequest("PUT", segments: ["settings", namespace]).sent(for: signIn)
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

nonisolated enum SettingsDocument: Equatable, Sendable {
    case neverWritten
    case stored(document: Data, revision: Int)
}

nonisolated enum SettingsWriteMode: Equatable, Sendable {
    case create
    case replace(revision: Int)
}

nonisolated enum SettingsWriteResult: Equatable, Sendable {
    case written(revision: Int)
    case conflict(document: Data, revision: Int)
}
