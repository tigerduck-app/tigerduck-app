import Foundation

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

    func forgetAll(on backend: URL) {
        let kept = load()
        let elsewhere = kept.filter { !AuthTokenManager.isSameBackend($0.baseURL, backend) }
        if elsewhere.count != kept.count { store(elsewhere) }
    }

    func add(_ session: DepartingSession) {
        store(load().filter { !AuthTokenManager.isSameBackend($0.baseURL, session.baseURL) } + [session])
    }
}
