import Foundation

/// Obtains and persists a long-lived Moodle Mobile App token through the NTUST OIDC SSO
/// launch flow the Moodle iOS app uses: `launch.php`, the SSO login form, the OIDC
/// `form_post` back to Moodle, then `moodlemobile://token=<base64>` on the final page.
///
/// Never POST to `/login/token.php` instead. NTUST Moodle is OIDC-only (auth_oidc), and that
/// endpoint counts every request as a failed login and triggers `login_lockout`, banning the
/// account within about 10 attempts. See docs/decisions/0019-moodle-oidc-token-flow.md.
actor MoodleTokenService {
    static let shared = MoodleTokenService(
        storedCredentials: {
            guard let studentId = KeychainManager.loadString(key: AppConstants.KeychainKeys.studentId),
                  let password = KeychainManager.loadString(key: AppConstants.KeychainKeys.password) else {
                return nil
            }
            return (studentId, password)
        },
        tokens: .keychain,
        harvest: { try await MoodleTokenHarvest.performOidcLogin(studentId: $0, password: $1) }
    )

    private let storedCredentials: @Sendable () -> (studentId: String, password: String)?
    private let tokens: TokenStore
    private let harvest: @Sendable (_ studentId: String, _ password: String) async throws -> TokenTriple
    private let now: @Sendable () -> Date

    struct TokenStore: Sendable {
        let load: @Sendable () -> String?
        let save: @Sendable (TokenTriple) -> Void
        let drop: @Sendable () -> Void

        static let keychain = TokenStore(
            load: { KeychainManager.loadString(key: AppConstants.KeychainKeys.moodleToken) },
            save: { triple in
                KeychainManager.saveString(key: AppConstants.KeychainKeys.moodleToken, value: triple.wstoken)
                if let pt = triple.privatetoken, !pt.isEmpty {
                    KeychainManager.saveString(key: AppConstants.KeychainKeys.moodlePrivateToken, value: pt)
                } else {
                    KeychainManager.delete(key: AppConstants.KeychainKeys.moodlePrivateToken)
                }
            },
            drop: {
                KeychainManager.delete(key: AppConstants.KeychainKeys.moodleToken)
                KeychainManager.delete(key: AppConstants.KeychainKeys.moodlePrivateToken)
            }
        )
    }

    private struct ObtainKey: Hashable {
        let studentId: String
        let passwordHash: Int
    }
    private var inFlightTokenTask: (key: ObtainKey, task: Task<String, Error>)?
    private var inFlightRefreshTask: Task<String, Error>?
    private var signIns = SignInCount()
    private var lastHarvestFailure: (at: Date, error: any Error)?
    nonisolated static let harvestPause: TimeInterval = 5 * 60

    init(
        storedCredentials: @escaping @Sendable () -> (studentId: String, password: String)?,
        tokens: TokenStore,
        harvest: @escaping @Sendable (_ studentId: String, _ password: String) async throws -> TokenTriple,
        now: @escaping @Sendable () -> Date = { Date() },
        harvestDeadline: Duration = MoodleTokenService.harvestDeadline
    ) {
        self.storedCredentials = storedCredentials
        self.tokens = tokens
        self.harvest = { studentId, password in
            try await Self.withinDeadline(harvestDeadline) { try await harvest(studentId, password) }
        }
        self.now = now
    }

    nonisolated static let harvestDeadline: Duration = .seconds(60)

    private nonisolated static func withinDeadline<T: Sendable>(
        _ deadline: Duration, _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await AppClock.sleep(until: ContinuousClock.now + deadline)
                throw MoodleWebserviceError.transientNetwork(underlying: URLError(.timedOut).localizedDescription)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }

    func obtainToken(studentId: String, password: String) async throws -> String {
        let normalizedId = studentId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let key = ObtainKey(studentId: normalizedId, passwordHash: password.hashValue)
        if let existing = inFlightTokenTask {
            if existing.key == key {
                return try await existing.task.value
            }
            _ = try? await existing.task.value
        }
        let ticket = signIns.ticket
        let task = Task<String, Error> {
            let triple = try await harvest(normalizedId, password)
            guard signIns.isCurrent(ticket) else { throw CancellationError() }
            tokens.save(triple)
            lastHarvestFailure = nil
            return triple.wstoken
        }
        inFlightTokenTask = (key, task)
        defer {
            if inFlightTokenTask?.task == task { inFlightTokenTask = nil }
        }
        return try await task.value
    }

    func refreshTokenIfNeeded(replacing rejected: String? = nil) async throws -> String {
        if let existing = inFlightRefreshTask {
            return try await existing.value
        }
        if let current = tokens.load() {
            guard current == rejected else { return current }
            tokens.drop()
        }
        guard !SchoolPasswordPosts.storedPasswordPostMustWait(now: now()) else {
            throw MoodleWebserviceError.ssoLoginRejected(reason: nil)
        }
        if let failure = lastHarvestFailure,
           case let age = now().timeIntervalSince(failure.at), age >= 0, age < Self.harvestPause {
            throw failure.error
        }
        let ticket = signIns.ticket
        let task = Task<String, Error> {
            let triple = try await SchoolPasswordPosts.postingStoredPassword {
                try await harvestWithStoredCredentials(ticket: ticket)
            }
            guard signIns.isCurrent(ticket) else { throw CancellationError() }
            tokens.save(triple)
            lastHarvestFailure = nil
            if triple.postedPassword { SchoolPasswordPosts.forgetStoredPasswordRefusals() }
            return triple.wstoken
        }
        inFlightRefreshTask = task
        defer {
            if inFlightRefreshTask == task { inFlightRefreshTask = nil }
        }
        return try await task.value
    }

    private func harvestWithStoredCredentials(ticket: AccountSession.Ticket) async throws -> TokenTriple {
        guard signIns.isCurrent(ticket) else { throw CancellationError() }
        guard !SchoolPasswordPosts.storedPasswordPostMustWait(now: now()) else {
            throw MoodleWebserviceError.ssoLoginRejected(reason: nil)
        }
        guard let creds = storedCredentials() else {
            throw MoodleWebserviceError.missingStoredCredentials
        }
        let normalizedId = creds.studentId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        do {
            return try await harvest(normalizedId, creds.password)
        } catch {
            if case MoodleWebserviceError.ssoLoginRejected = error {
                if signIns.isCurrent(ticket), storedCredentials()?.password == creds.password {
                    SchoolPasswordPosts.noteStoredPasswordRefused(at: now())
                }
            } else if signIns.isCurrent(ticket), !Self.isNetworkFailure(error) {
                lastHarvestFailure = (now(), error)
            }
            throw error
        }
    }

    private static func isNetworkFailure(_ error: any Error) -> Bool {
        if case MoodleWebserviceError.transientNetwork = error { return true }
        return false
    }

    func signOut() async {
        signIns.moveOn()
        lastHarvestFailure = nil
        inFlightTokenTask?.task.cancel()
        inFlightTokenTask = nil
        inFlightRefreshTask?.cancel()
        inFlightRefreshTask = nil
        await clearToken()
    }

    private func clearToken() async {
        tokens.drop()
        let purgeHosts: Set<String> = ["ssoam2.ntust.edu.tw", "moodle2.ntust.edu.tw"]
        HTTPCookieStorage.shared.cookies?
            .filter { cookie in
                let cleaned = String(cookie.domain.drop(while: { $0 == "." }))
                if purgeHosts.contains(cleaned) { return true }
                return purgeHosts.contains(where: { $0.hasSuffix("." + cleaned) })
            }
            .forEach { HTTPCookieStorage.shared.deleteCookie($0) }
        await MoodleSiteInfoService.shared.invalidateCache()
    }

    func currentToken() async -> String? {
        tokens.load()
    }

    struct TokenTriple: Sendable {
        let signature: String
        let wstoken: String
        let privatetoken: String?
        var postedPassword = false
    }

    nonisolated static func decodeTokenTriple(from base64Token: String) throws -> TokenTriple {
        // `Data(base64Encoded:)` takes only the standard padded alphabet, so map the URL-safe
        // `-` and `_` and pad. The extraction regex allows `-` and `_` since Moodle may emit
        // either encoding.
        var standardized = base64Token
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = standardized.count % 4
        if padding != 0 {
            standardized.append(String(repeating: "=", count: 4 - padding))
        }
        guard let decodedData = Data(base64Encoded: standardized),
              let decoded = String(data: decodedData, encoding: .isoLatin1) else {
            throw MoodleWebserviceError.malformedResponse(
                detail: "failed to base64-decode token triple",
            )
        }
        let parts = decoded.components(separatedBy: ":::")
        guard parts.count == 3 else {
            throw MoodleWebserviceError.malformedResponse(
                detail: "unexpected token triple (got \(parts.count) parts)",
            )
        }
        return TokenTriple(
            signature: parts[0],
            wstoken: parts[1],
            privatetoken: parts[2].isEmpty ? nil : parts[2],
        )
    }
}
