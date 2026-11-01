import Foundation

nonisolated struct DepartingSessionKeeper: Sendable {
    let list: DepartingSessionList
    let requests: AuthRequests

    var hasSession: Bool { !list.load().isEmpty }

    var backends: [URL] { list.load().map(\.baseURL) }

    func keepsAlongside(_ session: DepartingSession, of manager: isolated AuthTokenManager) -> Bool {
        !AuthTokenManager.isClaimedBySignIn(session.baseURL, signedIn: manager.isLoggedIn, backend: requests.baseURL())
    }

    @discardableResult
    func keep(_ session: DepartingSession, of manager: isolated AuthTokenManager) -> Bool {
        keepsAlongside(session, of: manager) && list.replaceIfStored(session)
    }

    func forget(_ session: DepartingSession, of manager: isolated AuthTokenManager) {
        list.forget(session)
    }

    private enum AnswerStillOut {
        case accessToken(String)
        case tokenSpent
        case noAnswer
    }

    func signOutToken(
        for departing: DepartingSession, access: String?, expiry: Date, refreshOut: Task<String?, Never>?,
        signIn: SignIn?, uses: Int, of manager: isolated AuthTokenManager
    ) async -> String? {
        if let access, Date.now < expiry.addingTimeInterval(-AuthTokenManager.signOutCallsWindow) { return access }
        if let refreshOut {
            switch await answer(of: refreshOut, for: departing, signIn: signIn, of: manager) {
            case .accessToken(let token): return token
            case .tokenSpent:
                forget(departing, of: manager)
                return nil
            case .noAnswer: break
            }
        }
        return await refreshDeparting(departing, uses: uses, of: manager)
    }

    private func answer(
        of refreshOut: Task<String?, Never>, for departing: DepartingSession, signIn: SignIn?,
        of manager: isolated AuthTokenManager
    ) async -> AnswerStillOut {
        _ = await refreshOut.value
        let late = manager.refreshes.lateBySentRefreshToken[departing.refreshToken].flatMap { $0.signIn == signIn ? $0 : nil }
        manager.refreshes.lateBySentRefreshToken = [:]
        guard let late else { return .noAnswer }
        if let token = late.accessToken {
            if let next = late.refreshToken { keep(departing.rotated(to: next), of: manager) }
            return .accessToken(token)
        }
        return late.mayResend ? .noAnswer : .tokenSpent
    }

    private func refreshDeparting(
        _ departing: DepartingSession, uses: Int, of manager: isolated AuthTokenManager
    ) async -> String? {
        guard UnconfirmedRefreshSends(uses: uses).allowsSend else {
            forget(departing, of: manager)
            return nil
        }
        guard spendLeftoverStoredToken(of: manager) else { return nil }
        if !keep(departing.counted(), of: manager) { forget(departing, of: manager) }
        return await refresh(departing, of: manager)
    }

    private func spendLeftoverStoredToken(of manager: isolated AuthTokenManager) -> Bool {
        guard manager.pair.refreshToken == nil || !manager.pair.refreshTokenIsStored else { return true }
        return manager.pair.tokens.saveConfirmed(AuthTokenManager.refreshTokenUsesKey, UnconfirmedRefreshSends.spent.stored)
    }

    func accessToken(for session: DepartingSession, of manager: isolated AuthTokenManager) async -> String? {
        guard session.budget.allowsSend else {
            forget(session, of: manager)
            return nil
        }
        guard keep(session.counted(), of: manager) else { return nil }
        let token = await refresh(session, of: manager)
        return keepsAlongside(session, of: manager) ? token : nil
    }

    func refresh(_ session: DepartingSession, of manager: isolated AuthTokenManager) async -> String? {
        struct RefreshResponse: Decodable {
            let access_token: String
            let refresh_token: String
        }
        let send = await requests.postRefresh(session.refreshToken, on: session.baseURL)
        if let status = send.status, status != 200 { await APIVersionGate.shared.note(statusCode: status) }
        if send.endedSession {
            forget(session, of: manager)
            return nil
        }
        if !send.mayHaveUsed { keep(session, of: manager) }
        guard send.status == 200, let data = send.reply?.0,
              let reply = try? JSONDecoder().decode(RefreshResponse.self, from: data) else { return nil }
        keep(session.rotated(to: reply.refresh_token), of: manager)
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
            let account = AuthTokenManager.DepartingAccount(accessToken: token, baseURL: target, sessionID: session.signOutID)
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
        if landed, let session { forget(session, of: manager) }
    }
}
