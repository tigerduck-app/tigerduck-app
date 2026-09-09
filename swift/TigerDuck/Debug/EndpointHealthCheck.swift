import Foundation

/// Probes a candidate API endpoint before the app commits to it.
///
/// The endpoint row lets anyone point the app at their own deployment of
/// the (open source) TigerDuck backend. Without a probe, a typo — a wrong
/// port, a stale LAN address, a host that answers but isn't the backend —
/// is only discovered later as every screen failing to load, from a
/// Settings row the user has already navigated away from. Checking here
/// turns that into an inline error at the moment of saving.
///
/// ## What counts as healthy
///
/// The server must answer `GET {origin}/health` with `200` and a JSON body
/// whose `status` is `"ok"`. That is the backend's own contract
/// (`server/main.py`), so requiring the shape — rather than accepting any
/// `200` — is what distinguishes "your backend is up" from "something on
/// this address served us a captive-portal page".
nonisolated enum EndpointHealthCheck {

    enum Result: Equatable {
        /// A TigerDuck backend answered.
        case ok
        /// Nothing answered, or the transport failed (DNS, TLS, timeout,
        /// connection refused). `detail` is the underlying description,
        /// for the inline error.
        case unreachable(detail: String)
        /// Something answered, but it did not look like this backend —
        /// wrong status code, non-JSON body, or no `"status": "ok"`.
        case notTigerDuck
    }

    /// Seconds before the probe gives up. Long enough for a cold container
    /// on a home server to wake, short enough that a wrong address doesn't
    /// leave the Save button spinning past the user's patience.
    private static let timeout: TimeInterval = 10

    /// The health URL for a given API base.
    ///
    /// `/health` is mounted at the FastAPI app root, a **sibling** of the
    /// version prefix rather than a child of it — so `…/v3` maps to
    /// `…/health`, and a deployment behind a path prefix
    /// (`…/tigerduck/v3`) maps to `…/tigerduck/health`. Dropping the last
    /// path component and appending `health` gets both right, where
    /// appending to the base would produce `…/v3/health` (404) and going
    /// to the bare origin would miss the prefixed deployment.
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
        // The probe answers "is this endpoint live *right now*", so a
        // cached 200 from a previous address would be exactly the wrong
        // answer.
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
