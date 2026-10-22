import Foundation

@MainActor
final class MoodleAutologinService {
    static let shared = MoodleAutologinService(keySource: { try await requestKey() })

    nonisolated static let keyInterval: TimeInterval = 360

    nonisolated static let keyWait: Duration = .seconds(3)

    nonisolated struct Key: Sendable {
        let userId: Int
        let value: String
        let autologinURL: String
    }

    private let keySource: @Sendable () async throws -> Key?
    private let now: () -> Date
    private let signInGeneration: () -> Int
    private let sleep: @Sendable (Duration) async -> Void
    private var lastKeyAt: Date?
    private(set) var isRequesting = false

    init(
        keySource: @escaping @Sendable () async throws -> Key?,
        now: @escaping () -> Date = { Date() },
        signInGeneration: @escaping () -> Int = { NTUSTSessionManager.shared.generation },
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.keySource = keySource
        self.now = now
        self.signInGeneration = signInGeneration
        self.sleep = sleep
    }

    func url(for url: URL) async -> URL {
        guard Self.isMoodlePage(url), !isRequesting, isKeyDue() else { return url }
        let generation = signInGeneration()
        guard let key = await answer(of: startKeyRequest(generation: generation)),
              signInGeneration() == generation else { return url }
        return Self.signedInURL(key, opening: url) ?? url
    }

    private func startKeyRequest(generation: Int) -> Task<Key?, Never> {
        isRequesting = true
        return Task {
            defer { isRequesting = false }
            let key: Key?
            do {
                key = try await keySource()
            } catch {
                AppLogger.breadcrumb("autologin key unavailable: \(error)", category: "moodle")
                return nil
            }
            guard let key, !key.value.isEmpty, signInGeneration() == generation else { return nil }
            lastKeyAt = now()
            return key
        }
    }

    private func answer(of request: Task<Key?, Never>) async -> Key? {
        let (answers, continuation) = AsyncStream<Key?>.makeStream()
        Task { continuation.yield(await request.value) }
        let deadline = Task { [sleep] in
            await sleep(Self.keyWait)
            continuation.yield(nil)
        }
        defer {
            deadline.cancel()
            continuation.finish()
        }
        for await key in answers { return key }
        return nil
    }

    private func isKeyDue() -> Bool {
        guard let lastKeyAt else { return true }
        let age = now().timeIntervalSince(lastKeyAt)
        return age >= Self.keyInterval || age < 0
    }

    nonisolated static func isMoodlePage(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == moodleHost
    }

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
