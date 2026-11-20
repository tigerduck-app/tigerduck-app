import Foundation
import os

nonisolated struct StoredTokenRefresher: Sendable {
    let requests: AuthRequests
    let beginBackgroundTask: @Sendable () async -> @Sendable () async -> Void

    func refresh(of manager: isolated AuthTokenManager) async -> String? {
        guard let refreshToken = manager.pair.refreshToken, let signIn = manager.pair.signIn else { return nil }
        let endBackgroundTask = await beginBackgroundTask()
        let token = await refreshStoredToken(refreshToken, signIn: signIn, of: manager)
        await endBackgroundTask()
        return token
    }

    private func refreshStoredToken(
        _ refreshToken: String, signIn: SignIn, of manager: isolated AuthTokenManager
    ) async -> String? {
        struct RefreshResponse: Decodable {
            let access_token: String
            let refresh_token: String
            let expires_in: Int
        }

        let pairBackend = requests.baseURL()
        guard pairUnchanged(signIn, holding: refreshToken, manager), manager.signOutsStarting.withLock({ $0 == 0 }) else {
            return nil
        }
        guard manager.pair.budget.allowsSend else {
            return await signedInAgain(as: signIn, of: manager) ? manager.pair.accessToken : nil
        }
        var send = await postCounted(refreshToken, after: manager.pair.budget, on: pairBackend, of: manager)
        if case .sent(let first, let budget) = send, first.reply == nil, holdsPair(of: signIn, manager), budget.allowsSend {
            send = await postCounted(refreshToken, after: budget, on: pairBackend, of: manager)
        }
        if manager.pair.refreshToken == refreshToken { manager.pair.budget = send.budget }
        let mayResend = send.budget.allowsSend
        if case .countRefused = send, await signedInAgain(as: signIn, of: manager) { return manager.pair.accessToken }
        guard case .sent(let reply, _) = send, let (data, http) = reply.reply else {
            noteOvertaken(signIn, sent: refreshToken, accessToken: nil, mayResend: mayResend, of: manager)
            return nil
        }

        if http.statusCode == 200 {
            guard let result = try? JSONDecoder().decode(RefreshResponse.self, from: data) else {
                noteOvertaken(signIn, sent: refreshToken, accessToken: nil, mayResend: mayResend, of: manager)
                return nil
            }
            guard pairUnchanged(signIn, holding: refreshToken, manager) else {
                noteOvertaken(
                    signIn, sent: refreshToken, accessToken: result.access_token,
                    refreshToken: result.refresh_token, mayResend: false, of: manager
                )
                return nil
            }
            manager.pair.store(access: result.access_token, refresh: result.refresh_token, expiresIn: result.expires_in, for: signIn)
            return result.access_token
        }

        await APIVersionGate.shared.note(statusCode: http.statusCode)
        guard holdsPair(of: signIn, manager) else {
            noteOvertaken(signIn, sent: refreshToken, accessToken: nil, mayResend: mayResend && !reply.turnedDown, of: manager)
            return nil
        }
        guard reply.turnedDown, pairUnchanged(signIn, holding: refreshToken, manager) else { return nil }

        if await signedInAgain(as: signIn, of: manager) { return manager.pair.accessToken }
        noteOvertaken(signIn, sent: refreshToken, accessToken: nil, mayResend: false, of: manager)
        guard reply.endedSession, pairUnchanged(signIn, holding: refreshToken, manager) else { return nil }
        manager.pair.clear()
        return nil
    }

    private func pairUnchanged(_ signIn: SignIn, holding refreshToken: String, _ manager: isolated AuthTokenManager) -> Bool {
        holdsPair(of: signIn, manager) && manager.pair.refreshToken == refreshToken
    }

    /// The rotated pair belongs to the stored session until `endSession` clears it, which a sign-out
    /// does after its sign-in ended; a reply before then is stored, one after it is left for the sign-out.
    private func holdsPair(of signIn: SignIn, _ manager: isolated AuthTokenManager) -> Bool {
        manager.pair.signIn == signIn
    }

    private func noteOvertaken(
        _ signIn: SignIn, sent: String, accessToken: String?, refreshToken: String? = nil,
        mayResend: Bool, of manager: isolated AuthTokenManager
    ) {
        guard !holdsPair(of: signIn, manager) else { return }
        manager.refreshes.lateBySentRefreshToken[sent] = AuthTokenManager.LateRefresh(
            signIn: signIn, accessToken: accessToken, refreshToken: refreshToken, mayResend: mayResend
        )
    }

    private func signedInAgain(as signIn: SignIn, of manager: isolated AuthTokenManager) async -> Bool {
        guard let relogin = manager.handlers.refreshFailed else { return false }
        return await relogin(signIn) && signIn.isCurrent
    }

    private enum CountedSend {
        case countRefused(UnconfirmedRefreshSends)
        case tokenReplaced(UnconfirmedRefreshSends)
        case sent(AuthRequests.RefreshSend, budget: UnconfirmedRefreshSends)

        var budget: UnconfirmedRefreshSends {
            switch self {
            case .countRefused(let budget), .tokenReplaced(let budget), .sent(_, let budget): budget
            }
        }
    }

    private func postCounted(
        _ refreshToken: String, after before: UnconfirmedRefreshSends, on backend: URL,
        of manager: isolated AuthTokenManager
    ) async -> CountedSend {
        guard manager.pair.saveBudget(before.afterSend(mayHaveUsed: true), of: refreshToken) else {
            return manager.pair.refreshToken == refreshToken ? .countRefused(before) : .tokenReplaced(before)
        }
        let send = await requests.postRefresh(refreshToken, on: backend)
        let after = before.afterSend(mayHaveUsed: send.mayHaveUsed)
        _ = manager.pair.saveBudget(after, of: refreshToken)
        return .sent(send, budget: after)
    }
}
