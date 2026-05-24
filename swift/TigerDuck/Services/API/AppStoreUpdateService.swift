import Foundation

/// Talks to Apple's public iTunes Lookup endpoint to discover whether a
/// newer build of this app has been published to the App Store.
///
/// **Lifecycle note**: until the iOS app ships publicly,
/// `resultCount == 0` for this bundle id — the service surfaces that as
/// ``LookupOutcome/noRecord``, the coordinator stamps the throttle (a
/// successful "no record" is still a successful answer) and quietly
/// no-ops without a prompt. The day the app lands on the App Store the
/// same code path activates with zero additional release work.
/// TestFlight builds are explicitly NOT indexed by this endpoint;
/// that's a known gap of the iTunes Lookup approach and the reason
/// this feature ships dormant during the TF phase.
enum AppStoreUpdateService {
    struct Lookup: Equatable {
        /// Latest marketing version on the App Store, e.g. `"1.8.0"`.
        let version: String
        /// App Store track id. Used to build the deep link
        /// `https://apps.apple.com/app/id<trackId>` that the Update Now
        /// button opens. iTunes Lookup uses `trackId`, not `bundleId`,
        /// for the App Store deep link — the latter has no canonical URL.
        let trackId: Int
        /// "What's New on the App Store" notes for the latest version, in
        /// the requesting Apple ID's locale (NOT the app's selected
        /// language). The What's New sheet uses the bundled per-version
        /// registry instead so the text stays in sync with the app
        /// locale; this field is captured for diagnostics only.
        let releaseNotes: String?
    }

    enum LookupError: Error {
        case invalidResponse
        case decodingFailed
    }

    static let lookupURL = URL.knownGood("https://itunes.apple.com/lookup")

    /// Discriminated result for `fetchLatest`. The caller needs to tell
    /// "Apple has no public record" (legit pre-launch state — stamp the
    /// throttle, don't surface a failure alert) from "couldn't reach
    /// Apple" (retry next foreground, surface failure on manual taps).
    enum LookupOutcome: Equatable {
        case found(Lookup)
        case noRecord
    }

    /// Fetch the App Store record for `bundleId`. Returns
    /// ``LookupOutcome/noRecord`` when Apple successfully responded
    /// but has no public record yet (TestFlight phase). Throws on
    /// network / decoding failures so the caller can distinguish those
    /// two paths.
    static func fetchLatest(
        bundleId: String,
        session: URLSession = .shared,
        country: String? = nil
    ) async throws -> LookupOutcome {
        var components = URLComponents(url: lookupURL, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [URLQueryItem(name: "bundleId", value: bundleId)]
        if let country, !country.isEmpty {
            // iTunes Lookup is per-storefront. Caller can scope to a
            // specific country (e.g. "tw") if the app is regionally
            // released; default leaves Apple to pick by the request IP.
            items.append(URLQueryItem(name: "country", value: country))
        }
        components.queryItems = items
        guard let url = components.url else { throw LookupError.invalidResponse }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LookupError.invalidResponse
        }

        let decoded: Envelope
        do {
            decoded = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw LookupError.decodingFailed
        }

        guard let first = decoded.results.first else { return .noRecord }
        return .found(Lookup(
            version: first.version,
            trackId: first.trackId,
            releaseNotes: first.releaseNotes
        ))
    }

    // MARK: - Wire format

    private struct Envelope: Decodable {
        let results: [Result]
    }

    private struct Result: Decodable {
        let version: String
        let trackId: Int
        let releaseNotes: String?
    }
}
