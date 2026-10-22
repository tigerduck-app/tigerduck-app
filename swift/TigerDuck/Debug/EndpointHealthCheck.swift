import Foundation

nonisolated enum EndpointHealthCheck {

    enum Result: Equatable {
        case ok
        case unreachable(detail: String)
        case notTigerDuck
    }

    private static let timeout: TimeInterval = 10

    static func healthURL(for base: URL) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var segments = components.path.split(separator: "/").map(String.init)
        if !segments.isEmpty { segments.removeLast() }
        segments.append("health")
        components.path = "/" + segments.joined(separator: "/")
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static func probe(_ base: URL) async -> Result {
        guard let url = healthURL(for: base) else {
            return .unreachable(detail: String(localized: "settings_api_endpoint_error_malformed"))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .notTigerDuck
            }
            guard
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let status = json["status"] as? String,
                status.lowercased() == "ok"
            else { return .notTigerDuck }
            return .ok
        } catch {
            return .unreachable(detail: error.localizedDescription)
        }
    }
}
