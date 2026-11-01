import Foundation

nonisolated enum EndpointHealthCheck {

    enum Result: Equatable {
        case ok
        case unreachable(detail: String)
        case notTigerDuck
    }

    private static let timeout: TimeInterval = 10

    static func healthURL(for base: URL) -> URL? {
        metaURL(for: base, named: "health")
    }

    static func versionURL(for base: URL) -> URL? {
        metaURL(for: base, named: "version")
    }

    private static func metaURL(for base: URL, named name: String) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var segments = components.path.split(separator: "/").map(String.init)
        if !segments.isEmpty { segments.removeLast() }
        segments.append(name)
        components.path = "/" + segments.joined(separator: "/")
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static func probe(_ base: URL, session: URLSession = .shared) async -> Result {
        guard let health = healthURL(for: base), let version = versionURL(for: base) else {
            return .unreachable(detail: String(localized: "settings_api_endpoint_error_malformed"))
        }
        do {
            guard let status = try await json(at: health, session: session)?["status"] as? String,
                  status.lowercased() == "ok",
                  let v4 = try await json(at: version, session: session)?["api_v4_base_path"] as? String,
                  !v4.isEmpty
            else { return .notTigerDuck }
            return .ok
        } catch {
            return .unreachable(detail: error.localizedDescription)
        }
    }

    private static func json(at url: URL, session: URLSession) async throws -> [String: Any]? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
