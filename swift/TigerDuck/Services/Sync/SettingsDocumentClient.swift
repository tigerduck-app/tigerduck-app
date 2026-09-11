import Foundation
import os

/// URLSession-based client for the backend's generic settings-document API
/// (`server/routes/settings_docs.py`): `GET/PUT /v3/settings/{namespace}`.
///
/// Mirrors `PushAPIClient`'s request construction, auth header and error
/// handling (`Services/Push/PushAPIClient.swift`) rather than introducing a
/// second networking stack — the same ephemeral `URLSession`, the same
/// `Bearer <token>` header via `authHeaderProvider`, and the same
/// `PushAPIError` for transport/decoding failures.
///
/// The document payload travels as opaque `Data` in both directions: this
/// client has no idea what shape any given namespace's document is (that's
/// a `Codable` type owned by the caller, e.g. `NotificationSettingsDocument`
/// for the `"notification"` namespace) — it only knows how to wrap it in
/// the `{"schema_version", "document", "base_revision"}` envelope the
/// backend expects, and unwrap the `{"document", "revision"}` (or, on a
/// conflict, `{"server": {"document", "revision"}}`) it returns.
actor SettingsDocumentClient {
    private let baseURLProvider: @Sendable () -> URL
    private let session: URLSession
    /// Returns a `Bearer <token>` string for the v3 JWT auth flow, or `nil`
    /// when the user is not logged in. See `PushAPIClient.authHeaderProvider`
    /// for why unauthenticated requests are still attempted rather than
    /// short-circuited client-side.
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

    // MARK: - Public surface

    /// GET the current document for `namespace`.
    ///
    /// `nil` means the user has never written to this namespace — the
    /// backend 404s (`settings_docs.py:read_document`), and that is the
    /// normal state for a fresh account, not an error the caller needs to
    /// handle specially.
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
        }
        return try Self.parseDocumentEnvelope(data)
    }

    /// PUT `document` to `namespace`.
    ///
    /// `baseRevision: nil` asks the backend to create the document; it
    /// 409s if one already exists. A non-nil value does a compare-and-swap
    /// and 409s if the server's revision has moved on since. Either way a
    /// 409 is not thrown as an error — the response carries the winning
    /// document and revision (`settings_docs.py:_conflict_response`) so
    /// the caller can merge and retry instead of just failing.
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
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let revision = json["revision"] as? Int
        else {
            throw PushAPIError.decodingFailed(
                NSError(domain: "SettingsAPI", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Missing 'revision' in response"])
            )
        }
        return .written(revision: revision)
    }

    // MARK: - Internals

    private func documentURL(for namespace: String) -> URL {
        baseURLProvider().appendingPathComponent("settings/\(Self.percentEncoded(namespace))")
    }

    private static func parseDocumentEnvelope(_ data: Data) throws -> (document: Data, revision: Int) {
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let revision = json["revision"] as? Int,
            let documentObject = json["document"]
        else {
            throw PushAPIError.decodingFailed(
                NSError(domain: "SettingsAPI", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Missing 'document' or 'revision' in response"])
            )
        }
        let documentData = try JSONSerialization.data(withJSONObject: documentObject, options: [.fragmentsAllowed])
        return (documentData, revision)
    }

    private static func parseConflict(_ data: Data) throws -> SettingsWriteResult {
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let server = json["server"] as? [String: Any],
            let revision = server["revision"] as? Int,
            let documentObject = server["document"]
        else {
            throw PushAPIError.decodingFailed(
                NSError(domain: "SettingsAPI", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Missing 'server.document' or 'server.revision' in 409 body"])
            )
        }
        let documentData = try JSONSerialization.data(withJSONObject: documentObject, options: [.fragmentsAllowed])
        return .conflict(document: documentData, revision: revision)
    }

    /// Attach the `Authorization: Bearer <token>` header when
    /// `authHeaderProvider` returns a non-nil value — same no-op-when-
    /// signed-out behaviour as `PushAPIClient.applyAuth`.
    private func applyAuth(to request: inout URLRequest) async {
        guard let header = await authHeaderProvider(), !header.isEmpty else { return }
        request.setValue(header, forHTTPHeaderField: "Authorization")
    }

    private func perform(_ request: URLRequest) async throws -> (data: Data, statusCode: Int) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PushAPIError.invalidResponse
        }
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

    /// Same allowlist as `PushAPIClient.percentEncoded`. Settings
    /// namespaces are fixed identifiers (`SETTINGS_NAMESPACES`), but path
    /// segments get the same treatment on principle.
    private static func percentEncoded(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) else {
            assertionFailure("percentEncoded failed for value of length \(value.count)")
            return ""
        }
        return encoded
    }
}

/// Outcome of `SettingsDocumentClient.write`. A 409 is not surfaced as a
/// thrown error — the caller needs the winning server document to merge
/// against, not just notice that its write lost.
///
/// `nonisolated` for the same reason as `NotificationSettingsDocument`:
/// this target defaults unannotated types to `@MainActor`
/// (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), but this is a plain
/// result value returned from the `SettingsDocumentClient` actor with no
/// actor affinity of its own — its `Equatable` conformance must stay
/// usable from any isolation domain.
nonisolated enum SettingsWriteResult: Equatable, Sendable {
    case written(revision: Int)
    case conflict(document: Data, revision: Int)
}
