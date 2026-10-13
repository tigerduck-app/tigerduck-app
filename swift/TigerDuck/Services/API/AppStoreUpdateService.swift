import Foundation

/// Asks Apple's public iTunes Lookup endpoint whether a newer build of this
/// app is on the App Store.
///
/// While the app is not on the App Store, `resultCount == 0` for its bundle
/// id: the service returns ``LookupOutcome/noRecord``, and the coordinator
/// stamps the throttle (a "no record" answer is still a success) and shows
/// no prompt. Once the app is listed, the same path works with no release
/// work. TestFlight builds are not indexed, so the feature is dormant there.
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
        /// Apple answered, but with a version ``AppVersion`` cannot read.
        case unparseableVersion
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
            version: normalizedVersion(first.version),
            trackId: first.trackId,
            releaseNotes: first.releaseNotes
        ))
    }

    /// The store version without a leading `v`. App Store Connect takes the
    /// version as free text and hands it back verbatim: 2.2.0 was entered
    /// as "v2.2.0", which ``AppVersion`` rejects, so the check read every
    /// installed build as current. Dropped here, where the string enters
    /// the app, so the comparison, the prompt's text and the Skip / Later
    /// markers all see the same bare number.
    static func normalizedVersion(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "v" || first == "V" else { return trimmed }
        return String(trimmed.dropFirst())
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
