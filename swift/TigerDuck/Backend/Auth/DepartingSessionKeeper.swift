import Foundation

nonisolated struct DepartingSessionKeeper: Sendable {
    let list: DepartingSessionList
    let requests: AuthRequests

    var hasSession: Bool { !list.load().isEmpty }

    var backends: [URL] { list.load().map(\.baseURL) }

    func keepsAlongside(_ session: DepartingSession, signedIn: Bool) -> Bool {
        !signedIn || !AuthTokenManager.isSameBackend(session.baseURL, requests.baseURL())
    }

    @discardableResult
    func keep(_ session: DepartingSession, signedIn: Bool) -> Bool {
        keepsAlongside(session, signedIn: signedIn) && list.keep(session)
    }

    func forget(_ session: DepartingSession) {
        list.forget(session)
    }

    func signOutToken(
        for departing: DepartingSession, access: String?, expiry: Date, refreshOut: Task<String?, Never>?,
        signIn: SignIn?, uses: Int, of manager: isolated AuthTokenManager
    ) async -> String? {
        if let access, Date.now < expiry.addingTimeInterval(-AuthTokenManager.signOutCallsWindow) { return access }
        if let refreshOut {
            _ = await refreshOut.value
            let late = manager.refreshes.late[departing.refreshToken].flatMap { $0.signIn == signIn ? $0 : nil }
            manager.refreshes.late = [:]
            if let late, let token = late.accessToken {
                if let next = late.refreshToken { keep(departing.rotated(to: next), signedIn: manager.isLoggedIn) }
                return token
            }
            if let late, !late.mayResend {
                forget(departing)
                return nil
            }
        }
        guard RefreshTokenUseBudget(uses: uses).allowsSend else {
            forget(departing)
            return nil
        }
        if manager.pair.refreshToken == nil || !manager.pair.refreshTokenIsStored {
            let spent = RefreshTokenUseBudget.spent.stored
            guard manager.pair.tokens.saveConfirmed(AuthTokenManager.refreshTokenUsesKey, spent) else { return nil }
        }
        if !keep(departing.counted(), signedIn: manager.isLoggedIn) { forget(departing) }
        return await refresh(departing, of: manager)
    }

    func accessToken(for session: DepartingSession, of manager: isolated AuthTokenManager) async -> String? {
        guard session.budget.allowsSend else {
            forget(session)
            return nil
        }
        guard keep(session.counted(), signedIn: manager.isLoggedIn) else { return nil }
        let token = await refresh(session, of: manager)
        return keepsAlongside(session, signedIn: manager.isLoggedIn) ? token : nil
    }

    func refresh(_ session: DepartingSession, of manager: isolated AuthTokenManager) async -> String? {
        struct RefreshResponse: Decodable {
            let access_token: String
            let refresh_token: String
        }
        let send = await requests.postRefresh(session.refreshToken, on: session.baseURL)
        let status = send.reply?.1.statusCode
        if let status, status != 200 { await APIVersionGate.shared.note(statusCode: status) }
        if status == 401 {
            forget(session)
            return nil
        }
        if !send.mayHaveUsed { keep(session, signedIn: manager.isLoggedIn) }
        guard status == 200, let data = send.reply?.0,
              let reply = try? JSONDecoder().decode(RefreshResponse.self, from: data) else { return nil }
        keep(session.rotated(to: reply.refresh_token), signedIn: manager.isLoggedIn)
        return reply.access_token
    }

    func retryUnregister(
        of manager: isolated AuthTokenManager, _ unregister: @MainActor @Sendable (_ backend: URL) async -> Bool
    ) async {
        let backend = requests.baseURL()
        for session in list.load()
        where AuthTokenManager.retriesKeptSession(on: session.baseURL, signedIn: manager.isLoggedIn, backend: backend) {
            guard let token = await accessToken(for: session, of: manager) else { continue }
            let target = session.baseURL
            let account = AuthTokenManager.DepartingAccount(accessToken: token, baseURL: target, sessionID: session.id)
            await self.unregister(session, as: account, of: manager) { await unregister(target) }
        }
    }

    func unregister(
        _ session: DepartingSession?, as account: AuthTokenManager.DepartingAccount,
        of manager: isolated AuthTokenManager, _ unregister: @MainActor @Sendable () async -> Bool
    ) async {
        let landed = await AuthTokenManager.$departing.withValue(account) {
            await unregister()
        }
        if landed, let session { forget(session) }
    }
}
