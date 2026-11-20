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
            guard let healthAnswer: Health = try await decoded(at: health, session: session),
                  healthAnswer.status.lowercased() == "ok",
                  let backendVersion: BackendVersion = try await decoded(at: version, session: session),
                  !backendVersion.apiV4BasePath.isEmpty
            else { return .notTigerDuck }
            return .ok
        } catch {
            return .unreachable(detail: error.localizedDescription)
        }
    }

    private struct Health: Decodable {
        let status: String
    }

    private struct BackendVersion: Decodable {
        let apiV4BasePath: String

        enum CodingKeys: String, CodingKey {
            case apiV4BasePath = "api_v4_base_path"
        }
    }

    private static func decoded<Body: Decodable>(at url: URL, session: URLSession) async throws -> Body? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Body.self, from: data)
    }
}
