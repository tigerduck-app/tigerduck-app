import Foundation

/// A session a sign-out could not unregister yet, one per backend. `id` names the sign-out that
/// kept it, through its rotations, so a retry that a newer sign-out overtook writes nothing; a
/// session an earlier version kept has none.
nonisolated struct DepartingSession: Codable, Sendable {
    var refreshToken: String
    var uses: Int
    var baseURL: URL
    var id: String?

    var budget: RefreshTokenUseBudget { RefreshTokenUseBudget(uses: uses) }

    func counted() -> DepartingSession {
        DepartingSession(refreshToken: refreshToken, uses: uses + 1, baseURL: baseURL, id: id)
    }

    func rotated(to next: String) -> DepartingSession {
        DepartingSession(refreshToken: next, uses: 0, baseURL: baseURL, id: id)
    }

    func isSame(as other: DepartingSession) -> Bool {
        id == other.id && AuthTokenManager.isSameBackend(baseURL, other.baseURL)
    }
}

/// The departing sessions, stored as one Keychain item beside the tokens.
nonisolated struct DepartingSessionList: Sendable {
    let tokens: AuthTokenManager.TokenStore

    func load() -> [DepartingSession] {
        tokens.load(AuthTokenManager.departingSessionKey)
            .flatMap { try? JSONDecoder().decode([DepartingSession].self, from: Data($0.utf8)) } ?? []
    }

    @discardableResult
    func store(_ sessions: [DepartingSession]) -> Bool {
        guard !sessions.isEmpty else { return tokens.deleteConfirmed(AuthTokenManager.departingSessionKey) }
        guard let data = try? JSONEncoder().encode(sessions) else { return false }
        return tokens.saveConfirmed(AuthTokenManager.departingSessionKey, String(decoding: data, as: UTF8.self))
    }

    /// Replaces the stored version of `session` only while it is still the one stored, so a retry
    /// a newer sign-out overtook writes nothing.
    @discardableResult
    func keep(_ session: DepartingSession) -> Bool {
        var sessions = load()
        guard let index = sessions.firstIndex(where: { $0.isSame(as: session) }) else { return false }
        sessions[index] = session
        return store(sessions)
    }

    func forget(_ session: DepartingSession) {
        let sessions = load()
        guard sessions.contains(where: { $0.isSame(as: session) }) else { return }
        store(sessions.filter { !$0.isSame(as: session) })
    }

    /// Drops the ones kept on `backend`, as a sign-in there gave the device to the new account.
    func forgetAll(on backend: URL) {
        let kept = load()
        let elsewhere = kept.filter { !AuthTokenManager.isSameBackend($0.baseURL, backend) }
        if elsewhere.count != kept.count { store(elsewhere) }
    }

    /// Keeps `session` as the one of its backend, in place of an earlier sign-out's.
    func add(_ session: DepartingSession) {
        store(load().filter { !AuthTokenManager.isSameBackend($0.baseURL, session.baseURL) } + [session])
    }
}
