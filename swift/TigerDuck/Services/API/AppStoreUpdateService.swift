import Foundation

enum AppStoreUpdateService {
    struct Lookup: Equatable {
        let version: String
        let trackId: Int
        let releaseNotes: String?
    }

    enum LookupError: Error {
        case invalidResponse
        case decodingFailed
        case unparseableVersion
    }

    static let lookupURL = URL.knownGood("https://itunes.apple.com/lookup")

    enum LookupOutcome: Equatable {
        case found(Lookup)
        case noRecord
    }

    static func fetchLatest(
        bundleId: String,
        session: URLSession = .shared,
        country: String? = nil
    ) async throws -> LookupOutcome {
        var components = URLComponents(url: lookupURL, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [URLQueryItem(name: "bundleId", value: bundleId)]
        if let country, !country.isEmpty {
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

    static func normalizedVersion(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "v" || first == "V" else { return trimmed }
        return String(trimmed.dropFirst())
    }

    private struct Envelope: Decodable {
        let results: [Result]
    }

    private struct Result: Decodable {
        let version: String
        let trackId: Int
        let releaseNotes: String?
    }
}
    /// The store version without a leading `v`. App Store Connect takes the
    /// version as free text and hands it back verbatim: 2.2.0 was entered
    /// as "v2.2.0", which ``AppVersion`` rejects, so the check read every
    /// installed build as current. Dropped here, where the string enters
    /// the app, so the comparison, the prompt's text and the Skip / Later
    /// markers all see the same bare number.
