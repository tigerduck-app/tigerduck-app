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

        let backend = requests.baseURL()
        guard signIn.isCurrent, manager.signOutsStarting.withLock({ $0 == 0 }),
              manager.pair.refreshToken == refreshToken else { return nil }
        guard manager.pair.budget.allowsSend else {
            return await signedInAgain(as: signIn, of: manager) ? manager.pair.accessToken : nil
        }
        var send = await postCounted(refreshToken, after: manager.pair.budget, on: backend, of: manager)
        if send.reply == nil, !send.uncounted, signIn.isCurrent, send.budget.allowsSend {
            send = await postCounted(refreshToken, after: send.budget, on: backend, of: manager)
        }
        if manager.pair.refreshToken == refreshToken { manager.pair.budget = send.budget }
        let reply = send.reply
        let mayResend = send.budget.allowsSend
        if send.uncounted, await signedInAgain(as: signIn, of: manager) { return manager.pair.accessToken }
        guard let (data, http) = reply else {
            noteOvertaken(signIn, sent: refreshToken, accessToken: nil, mayResend: mayResend, of: manager)
            return nil
        }

        if http.statusCode == 200 {
            guard let result = try? JSONDecoder().decode(RefreshResponse.self, from: data) else {
                noteOvertaken(signIn, sent: refreshToken, accessToken: nil, mayResend: mayResend, of: manager)
                return nil
            }
            guard signIn.isCurrent, manager.pair.refreshToken == refreshToken else {
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
        let turnedDown = Self.turnsDown(http.statusCode)
        guard signIn.isCurrent else {
            noteOvertaken(signIn, sent: refreshToken, accessToken: nil, mayResend: mayResend && !turnedDown, of: manager)
            return nil
        }
        guard turnedDown, manager.pair.refreshToken == refreshToken else { return nil }

        if await signedInAgain(as: signIn, of: manager) { return manager.pair.accessToken }
        noteOvertaken(signIn, sent: refreshToken, accessToken: nil, mayResend: false, of: manager)
        guard http.statusCode == 401, signIn.isCurrent, manager.pair.refreshToken == refreshToken else {
            return nil
        }
        manager.pair.clear()
        return nil
    }

    private static func turnsDown(_ statusCode: Int) -> Bool {
        (400...499).contains(statusCode) && ![410, 429].contains(statusCode)
    }

    private func noteOvertaken(
        _ signIn: SignIn, sent: String, accessToken: String?, refreshToken: String? = nil,
        mayResend: Bool, of manager: isolated AuthTokenManager
    ) {
        guard !signIn.isCurrent else { return }
        manager.refreshes.late[sent] = (signIn, accessToken, refreshToken, mayResend)
    }

    private func signedInAgain(as signIn: SignIn, of manager: isolated AuthTokenManager) async -> Bool {
        guard let relogin = manager.handlers.refreshFailed else { return false }
        return await relogin(signIn) && signIn.isCurrent
    }

    private func postCounted(
        _ refreshToken: String, after before: RefreshTokenUseBudget, on backend: URL,
        of manager: isolated AuthTokenManager
    ) async -> (reply: (Data, HTTPURLResponse)?, budget: RefreshTokenUseBudget, uncounted: Bool) {
        guard manager.pair.saveBudget(before.afterSend(mayHaveUsed: true), of: refreshToken) else {
            return (nil, before, manager.pair.refreshToken == refreshToken)
        }
        let send = await requests.postRefresh(refreshToken, on: backend)
        let after = before.afterSend(mayHaveUsed: send.mayHaveUsed)
        _ = manager.pair.saveBudget(after, of: refreshToken)
        return (send.reply, after, false)
    }
}
