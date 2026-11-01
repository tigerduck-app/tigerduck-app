import Foundation
import TigerDuckCore

nonisolated enum MoodleWebserviceClient {
    static let webservicePath = "/webservice/rest/server.php"
    static let session: URLSession = {
        let userAgent = (
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 "
            + "MoodleMobile 5.1.1 (51100)"
        )
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = [
            "User-Agent": userAgent,
            "Accept-Language": "zh-TW,zh;q=0.9,en-US;q=0.8,en;q=0.7",
        ]
        return SchoolSessions.pinned(config)
    }()

    struct TokenSource: Sendable {
        let stored: @Sendable () async -> String?
        let renew: @Sendable (_ rejected: String?) async throws -> String

        static let keychain = TokenSource(
            stored: { await MoodleTokenService.shared.currentToken() },
            renew: { try await MoodleTokenService.shared.refreshTokenIfNeeded(replacing: $0) }
        )
    }

    /// An access error gets one more try with the same token: Moodle answers an expired token
    /// with `accessexception` once and deletes it, then answers `invalidtoken`. A function the
    /// site does not allow fails the same way twice and starts no renewal.
    static func withRenewingToken<T>(
        _ tokens: TokenSource = .keychain,
        _ body: (String) async throws -> T
    ) async throws -> T {
        let token = if let stored = await tokens.stored() { stored } else { try await tokens.renew(nil) }
        do {
            do {
                return try await body(token)
            } catch MoodleWebserviceError.accessDenied {
                return try await body(token)
            }
        } catch MoodleWebserviceError.invalidToken {
            return try await body(try await tokens.renew(token))
        }
    }

    /// A Moodle error body throws its case whatever the HTTP status, since Moodle sends most
    /// errors with a 200. A 503 with `Retry-After` is Moodle's CLI maintenance page, which an
    /// upgrade shows for every request.
    static func call<T: Decodable & Sendable>(
        _ function: String,
        params: [(String, String)] = [],
        token: String,
        as type: T.Type,
        session: URLSession = MoodleWebserviceClient.session,
        siteURL: URL = AppConstants.moodleBaseURL
    ) async throws -> T {
        guard var components = URLComponents(url: siteURL, resolvingAgainstBaseURL: false) else {
            throw MoodleWebserviceError.malformedResponse(detail: "invalid base URL")
        }
        components.path = webservicePath
        components.queryItems = [
            URLQueryItem(name: "moodlewsrestformat", value: "json"),
            URLQueryItem(name: "wsfunction", value: function),
        ]
        guard let url = components.url else {
            throw MoodleWebserviceError.malformedResponse(detail: "invalid webservice URL for \(function)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formCarrying(token: token, params)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: CredentialPostDelegate())
        } catch let urlError as URLError {
            throw MoodleWebserviceError.transientNetwork(underlying: urlError.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw MoodleWebserviceError.malformedResponse(detail: "No HTTP response")
        }
        let status = http.statusCode
        let underMaintenance = status == 503 && http.value(forHTTPHeaderField: "Retry-After") != nil
        return try await Task.detached(priority: .userInitiated) {
            if let moodleError = MoodleWebserviceError.from(jsonData: data) { throw moodleError }
            if underMaintenance { throw MoodleWebserviceError.siteMaintenance }
            guard status == 200 else { throw MoodleWebserviceError.httpStatus(code: status) }
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw MoodleWebserviceError.malformedResponse(detail: "Unable to decode \(function): \(error)")
            }
        }.value
    }

    /// Server and proxy access logs keep URLs, so a token goes only in a form body.
    static func formCarrying(token: String, as field: String = "wstoken", _ params: [(String, String)] = []) -> Data {
        Data(formBody([(field, token)] + params).utf8)
    }

    static func formBody(_ params: [(String, String)]) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return params.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: unreserved) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }
        .joined(separator: "&")
    }
}

struct MoodleEnrolledCourse: Sendable {
    let id: Int
    let fullname: String
    let shortname: String
    let idnumber: String
    let startDate: Date?
    let endDate: Date?

    var courseNo: String {
        guard semester.isEmpty == false else { return "" }
        return String(idnumber.dropFirst(4))
    }

    var semester: String {
        AcademicTerm.codePrefix(ofMoodleId: idnumber) ?? ""
    }

    fileprivate var rawSemesterPrefix: String {
        semester.isEmpty ? "" : String(idnumber.prefix(4))
    }
}

extension MoodleEnrolledCourse {
    private static let courseNoToken = /(?:3?[A-Z]{2,3}|3[A-Z])[0-9][A-Z0-9]{5,6}/

    var courseNos: [String] {
        guard !courseNo.isEmpty else { return [] }
        var seen: Set<String> = [courseNo]
        return [courseNo] + fullname
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .compactMap { $0.wholeMatch(of: Self.courseNoToken).map { String($0.output) } }
            .filter { seen.insert($0).inserted }
    }

    var idnumbers: [String] { courseNos.map { rawSemesterPrefix + $0 } }
}
