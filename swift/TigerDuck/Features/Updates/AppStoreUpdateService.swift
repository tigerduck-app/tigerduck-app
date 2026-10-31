import Defaults
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

    private struct Envelope: Decodable {
        let results: [Result]
    }

    private struct Result: Decodable {
        let version: String
        let trackId: Int
        let releaseNotes: String?
    }
}

/// The App Store lookup the update check makes: one at a time, shared by every caller that asks
/// while it runs.
@MainActor
final class AppStoreLookup {
    typealias ErrorReporter = @Sendable (any Error, [String: String]) -> Void

    enum Result: Equatable {
        case found(AppStoreUpdateService.Lookup)
        case noRecord
        case failed
    }

    private let bundleId: String
    private let session: URLSession
    private let reportError: ErrorReporter
    private var inFlight: Task<Result, Never>?

    nonisolated init(bundleId: String, session: URLSession, reportError: @escaping ErrorReporter) {
        self.bundleId = bundleId
        self.session = session
        self.reportError = reportError
    }

    func latest() async -> Result {
        if let existing = inFlight {
            return await existing.value
        }
        let task = Task<Result, Never> { [bundleId, session, reportError] in
            do {
                // Pin the storefront so users abroad / on a VPN don't
                // get an IP-inferred storefront that returns no record
                // and silently masks an available update.
                let outcome = try await AppStoreUpdateService.fetchLatest(
                    bundleId: bundleId,
                    session: session,
                    country: AppConstants.appStoreLookupStorefront
                )
                switch outcome {
                case .found(let lookup): return .found(lookup)
                case .noRecord: return .noRecord
                }
            } catch {
                reportError(error, ["phase": "AppStoreUpdateService.fetchLatest"])
                return .failed
            }
        }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }

    /// The store page of whatever the lookup finds, unreported when it fails.
    func anyStoreLink() async -> URL? {
        guard case .found(let lookup)? = try? await AppStoreUpdateService.fetchLatest(
            bundleId: bundleId, session: session, country: AppConstants.appStoreLookupStorefront
        ) else { return nil }
        return Self.storeLink(trackId: lookup.trackId)
    }

    func reportUnparseableVersion(_ version: String) {
        guard Defaults[.lastReportedUnparseableStoreVersion] != version else { return }
        Defaults[.lastReportedUnparseableStoreVersion] = version
        reportError(
            AppStoreUpdateService.LookupError.unparseableVersion,
            [
                "phase": "UpdateNotifyCoordinator.performCheck",
                "storeVersion": version,
            ]
        )
    }

    nonisolated static func storeLink(trackId: Int) -> URL {
        var components = URLComponents()
        #if os(macOS)
        components.scheme = "macappstore"
        #else
        components.scheme = "https"
        #endif
        components.host = "apps.apple.com"
        components.path = "/app/id\(trackId)"
        return components.url ?? URL(string: "https://apps.apple.com/app/id\(trackId)")!
    }
}
