import Foundation

/// A response body with the ETag it came with, kept for the next conditional GET.
nonisolated struct ETaggedBody: Codable, Equatable, Sendable {
    let body: Data
    let etag: String?
}

/// The conditional GET (RFC 9110 section 13.1.2) of every cached answer that carries an ETag.
/// The request sends the stored copy's ETag. A 304 answers nil and the caller keeps its copy; any
/// other answer brings the body with its new ETag, which the caller stores once it has read it.
/// A failure throws before the caller writes anything, so its copy stands.
nonisolated struct ConditionalGet: Sendable {
    let etag: String?

    /// URLCache would answer the revalidation itself and hide the 304, so the request skips it.
    func request(_ request: URLRequest) -> URLRequest {
        var request = request
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let etag, !etag.isEmpty { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        return request
    }

    static func answer(_ body: Data, _ response: HTTPURLResponse) -> ETaggedBody? {
        response.statusCode == 304 ? nil : ETaggedBody(body: body, etag: response.value(forHTTPHeaderField: "ETag"))
    }
}

nonisolated extension BackendClient {
    /// Sends `request` as a conditional GET of the copy `etag` came with: nil for a 304, otherwise
    /// the new copy with the status, a 2xx or one `request.returnedStatuses` lets through.
    func revalidate(_ request: BackendRequest, etag: String?) async throws -> (copy: ETaggedBody, status: Int)? {
        var request = request
        request.conditional = ConditionalGet(etag: etag)
        request.returnedStatuses.insert(304)
        let response = try await send(request)
        return ConditionalGet.answer(response.data, response.http).map { ($0, response.status) }
    }
}
