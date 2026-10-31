import Foundation
import os

/// The refresh of the stored pair's token. It runs isolated to the `AuthTokenManager` it is given,
/// as the manager's own did, so every check reads the pair as it is after the await before it.
nonisolated struct StoredTokenRefresher: Sendable {
    let requests: AuthRequests
    let beginBackgroundTask: @Sendable () async -> @Sendable () async -> Void

    func refresh(of manager: isolated AuthTokenManager) async -> String? {
        guard let refreshToken = manager.pair.refreshToken else { return nil }
        let ticket = manager.signIns.ticket
        let endBackgroundTask = await beginBackgroundTask()
        let token = await refreshStoredToken(refreshToken, ticket: ticket, of: manager)
        await endBackgroundTask()
        return token
    }

    /// Sends only the token it was started for, the one a sign-out counts a refresh still out against.
    private func refreshStoredToken(
        _ refreshToken: String, ticket: AccountSession.Ticket, of manager: isolated AuthTokenManager
    ) async -> String? {
        struct RefreshResponse: Decodable {
            let access_token: String
            let refresh_token: String
            let expires_in: Int
        }

        // Read before the check: a sign-out holds the tokens before it stores another endpoint.
        // The resend goes where the first send went, whatever endpoint is stored meanwhile.
        let backend = requests.baseURL()
        guard manager.signIns.isCurrent(ticket), manager.signOutsStarting.withLock({ $0 == 0 }),
              manager.pair.refreshToken == refreshToken else { return nil }
        guard manager.pair.budget.allowsSend else {
            return await signedInAgain(since: ticket, of: manager) ? manager.pair.accessToken : nil
        }
        var send = await postCounted(refreshToken, after: manager.pair.budget, on: backend, of: manager)
        if send.reply == nil, !send.uncounted, manager.signIns.isCurrent(ticket), send.budget.allowsSend {
            send = await postCounted(refreshToken, after: send.budget, on: backend, of: manager)
        }
        if manager.pair.refreshToken == refreshToken { manager.pair.budget = send.budget }
        let reply = send.reply
        let mayResend = send.budget.allowsSend
        // A sign-in sends no refresh token, so a Keychain that refuses every count still leaves a session.
        if send.uncounted, await signedInAgain(since: ticket, of: manager) { return manager.pair.accessToken }
        guard let (data, http) = reply else {
            noteOvertaken(ticket, sent: refreshToken, accessToken: nil, mayResend: mayResend, of: manager)
            return nil
        }

        if http.statusCode == 200 {
            guard let result = try? JSONDecoder().decode(RefreshResponse.self, from: data) else {
                noteOvertaken(ticket, sent: refreshToken, accessToken: nil, mayResend: mayResend, of: manager)
                return nil
            }
            // A sign-in that stored its pair meanwhile ended this token's session on the backend.
            guard manager.signIns.isCurrent(ticket), manager.pair.refreshToken == refreshToken else {
                noteOvertaken(
                    ticket, sent: refreshToken, accessToken: result.access_token,
                    refreshToken: result.refresh_token, mayResend: false, of: manager
                )
                return nil
            }
            manager.pair.store(access: result.access_token, refresh: result.refresh_token, expiresIn: result.expires_in)
            return result.access_token
        }

        await APIVersionGate.shared.note(statusCode: http.statusCode)
        let turnedDown = Self.turnsDown(http.statusCode)
        guard manager.signIns.isCurrent(ticket) else {
            noteOvertaken(ticket, sent: refreshToken, accessToken: nil, mayResend: mayResend && !turnedDown, of: manager)
            return nil
        }
        // A refusal of a token a sign-in has replaced says nothing of the sign-in's pair.
        guard turnedDown, manager.pair.refreshToken == refreshToken else { return nil }

        if await signedInAgain(since: ticket, of: manager) { return manager.pair.accessToken }
        noteOvertaken(ticket, sent: refreshToken, accessToken: nil, mayResend: false, of: manager)
        guard http.statusCode == 401, manager.signIns.isCurrent(ticket), manager.pair.refreshToken == refreshToken else {
            return nil
        }
        manager.pair.clear()
        return nil
    }

    private static func turnsDown(_ statusCode: Int) -> Bool {
        (400...499).contains(statusCode) && ![410, 429].contains(statusCode)
    }

    private func noteOvertaken(
        _ ticket: AccountSession.Ticket, sent: String, accessToken: String?, refreshToken: String? = nil,
        mayResend: Bool, of manager: isolated AuthTokenManager
    ) {
        guard !manager.signIns.isCurrent(ticket) else { return }
        manager.refreshes.late[sent] = (ticket, accessToken, refreshToken, mayResend)
    }

    private func signedInAgain(since ticket: AccountSession.Ticket, of manager: isolated AuthTokenManager) async -> Bool {
        guard let relogin = manager.handlers.refreshFailed else { return false }
        return await relogin() && manager.signIns.isCurrent(ticket)
    }

    /// `uncounted` when the Keychain refused the count, so nothing went out. A token a sign-in
    /// replaced meanwhile is not sent either, but it is no longer this refresh's to sign in for.
    /// The budget is counted before the send, so an app that ends during it still counts it.
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
