import Foundation

/// Opens Moodle pages signed in, as the Moodle app does: `tool_mobile_get_autologin_key` trades
/// the stored private token for a one-time key, and Moodle's `autologin.php` signs the browser in
/// with it before it goes on to the page. Without a key the page opens as it is, signed out.
actor MoodleAutologinService {
    static let shared = MoodleAutologinService(keySource: { try await requestKey() })

    /// Moodle gives an account one key in this many seconds (`autologinmintimebetweenreq`, 360 on
    /// NTUST) and refuses the rest, counting the keys the Moodle app asks for too.
    static let keyInterval: TimeInterval = 360

    nonisolated struct Key: Sendable {
        let userId: Int
        let value: String
        let autologinURL: String
    }

    private let keySource: @Sendable () async throws -> Key?
    private let now: @Sendable () -> Date
    private var lastKeyAt: Date?
    private var isRequesting = false

    /// `now` defaults to the real clock, not `AppClock`: Moodle counts ``keyInterval`` in real
    /// time, and a debug clock override would stretch or skip it.
    init(
        keySource: @escaping @Sendable () async throws -> Key?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.keySource = keySource
        self.now = now
    }

    /// `url` behind a one-time sign-in when it is an HTTPS page on the Moodle site, else `url`.
    /// `url` also comes back as it is while a key is on its way, within ``keyInterval`` of the
    /// last key, and when the request fails, which is not retried.
    func url(for url: URL) async -> URL {
        guard Self.isMoodlePage(url), !isRequesting, isKeyDue() else { return url }
        isRequesting = true
        defer { isRequesting = false }
        let key: Key?
        do {
            key = try await keySource()
        } catch {
            AppLogger.breadcrumb("autologin key unavailable: \(error)", category: "moodle")
            return url
        }
        guard let key, !key.value.isEmpty else { return url }
        lastKeyAt = now()
        return Self.signedInURL(key, opening: url) ?? url
    }

    /// A last key stamped ahead of the clock, left by a clock set back, counts as old.
    private func isKeyDue() -> Bool {
        guard let lastKeyAt else { return true }
        let age = now().timeIntervalSince(lastKeyAt)
        return age >= Self.keyInterval || age < 0
    }

    nonisolated static func isMoodlePage(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == moodleHost
    }

    /// The `autologin.php` link from `key` with the account, the key and the page to go on to, or
    /// nil when that link is not HTTPS on the Moodle site, so the key never goes to another host.
    nonisolated static func signedInURL(_ key: Key, opening url: URL) -> URL? {
        guard var components = URLComponents(string: key.autologinURL),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == moodleHost else { return nil }
        components.percentEncodedQuery = MoodleWebserviceClient.formBody([
            ("userid", String(key.userId)),
            ("key", key.value),
            ("urltogo", url.absoluteString),
        ])
        return components.url
    }

    private nonisolated static let moodleHost = AppConstants.moodleBaseURL.host?.lowercased()

    /// Asks Moodle for a key under the stored token, which is renewed as for any Moodle call. The
    /// private token goes in the POST body, since Moodle refuses one in the query, and is read
    /// again inside because a renewed token comes with its own. Nil without a private token.
    nonisolated static func requestKey(
        tokens: MoodleWebserviceClient.TokenSource = .keychain,
        privateToken: () -> String? = {
            KeychainManager.loadString(key: AppConstants.KeychainKeys.moodlePrivateToken)
        },
        userId: (_ token: String) async throws -> Int = { try await MoodleSiteInfoService.shared.userId(token: $0) },
        session: URLSession = MoodleWebserviceClient.session,
        siteURL: URL = AppConstants.moodleBaseURL
    ) async throws -> Key? {
        guard privateToken() != nil else { return nil }
        return try await MoodleWebserviceClient.withToken(tokens) { token in
            guard let privateToken = privateToken() else { return nil }
            let userId = try await userId(token)
            let answer = try await MoodleWebserviceClient.call(
                "tool_mobile_get_autologin_key",
                params: [("privatetoken", privateToken)],
                token: token,
                as: KeyAnswer.self,
                session: session,
                siteURL: siteURL
            )
            return Key(userId: userId, value: answer.key, autologinURL: answer.autologinurl)
        }
    }

    private nonisolated struct KeyAnswer: Decodable, Sendable {
        let key: String
        let autologinurl: String
    }
}
