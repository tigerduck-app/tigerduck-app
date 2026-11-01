#if os(iOS)
import Foundation

@MainActor
final class MailPageSession {
    private let open: () async throws -> any MailClient
    private var client: (any MailClient)?
    /// The open under way and the sign-in it was started in; a later sign-in opens its own.
    private var opening: (task: Task<any MailClient, Error>, signIn: SignIn)?
    private let idleClose: MailIdleClose
    private var inFlight = 0
    private var isReleased = false
    private var pendingDrop = false
    private let onAuthFailure: @MainActor (SignIn) -> Void
    let account: AccountSession
    private var signOutListener: MailSignOutListener?

    init(
        idleClose: Duration = .seconds(MailConstants.connectionIdleClose),
        open: @escaping () async throws -> any MailClient = { try await MailAccountManager.shared.openSession() },
        onAuthFailure: @escaping @MainActor (SignIn) -> Void = { MailAccountManager.shared.handleAuthFailure(for: $0) },
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await AppClock.sleep(until: ContinuousClock.now + $0) },
        signOutEvents: NotificationCenter = .default,
        account: AccountSession? = nil
    ) {
        self.account = account ?? MailAccountManager.shared.session
        self.idleClose = MailIdleClose(delay: idleClose, sleep: sleep)
        self.open = open
        self.onAuthFailure = onAuthFailure
        signOutListener = MailSignOutListener(center: signOutEvents) { [weak self] in self?.invalidateForSignOut() }
    }

    func use<T>(_ body: (any MailClient) async throws -> T) async throws -> T {
        let signIn = await account.startingSignIn
        cancelClose()
        inFlight += 1
        let client: any MailClient
        do {
            client = try await resolveClient(for: signIn)
        } catch {
            reportIfAuthenticationRejected(error, for: signIn)
            await endUse()
            throw error
        }
        do {
            let result = try await body(client)
            await endUse()
            return result
        } catch {
            if MailErrorClass(error)?.closesConnection == true { pendingDrop = true }
            reportIfAuthenticationRejected(error, for: signIn)
            await endUse()
            throw error
        }
    }

    /// The choke point that keeps a rejected password from being sent again covers everything
    /// the page does, not only the sign-in that opened the connection. SMTP `AUTH LOGIN` and the
    /// held connection's own relogin run inside a `use(_:)` body, never through
    /// `MailAccountManager.openSession()`, so without this they would leave `authFailed` unset
    /// and the next tap would send the rejected password again. NTUST locks the account (and
    /// its Wi-Fi) after repeated failures, so every layer reports here.
    private func reportIfAuthenticationRejected(_ error: any Error, for signIn: SignIn) {
        guard (error as? MailClientError) == .authenticationFailed else { return }
        reportAuthenticationRejection(for: signIn)
    }

    /// Reports a rejected password a `use(_:)` body caught and did not rethrow.
    /// `use(_:)` only hears about a rejection thrown as an error, and filing the sent copy is
    /// best-effort: it must never fail a send that already succeeded (`SentCopyFiler`), so its
    /// `.authenticationFailed` is caught and turned into an outcome. NTUST locks the account (and
    /// its Wi-Fi) after repeated failures, so that caller reports here, reaching the same choke
    /// point a thrown error would.
    func reportAuthenticationRejection(for signIn: SignIn) {
        guard signIn.isCurrent else { return }
        onAuthFailure(signIn)
    }

    func releaseSoon() {
        isReleased = true
        if inFlight == 0 { armClose() }
    }

    func close() async {
        idleClose.cancel()
        isReleased = false
        pendingDrop = false
        let current = client
        client = nil
        await current?.logout()
    }

    func invalidateForSignOut() {
        idleClose.cancel()
        isReleased = false
        pendingDrop = false
        opening = nil
        let stale = client
        client = nil
        if let stale { Task { await stale.logout() } }
    }

    private func endUse() async {
        inFlight -= 1
        guard inFlight == 0 else { return }
        if pendingDrop {
            await close()
        } else if isReleased {
            armClose()
        }
    }

    private func resolveClient(for signIn: SignIn) async throws -> any MailClient {
        if let client { return client }
        if let opening, opening.signIn.isCurrent {
            let opened = try await opening.task.value
            guard signIn.isCurrent else { throw CancellationError() }
            return opened
        }
        let task = Task { try await open() }
        opening = (task, signIn)
        defer { if opening?.task == task { opening = nil } }
        let opened = try await task.value
        guard signIn.isCurrent else {
            await opened.logout()
            throw CancellationError()
        }
        client = opened
        return opened
    }

    private func cancelClose() {
        idleClose.cancel()
        isReleased = false
    }

    private func armClose() {
        idleClose.arm { [weak self] in await self?.fireClose() }
    }

    private func fireClose() async {
        guard inFlight == 0 else { return }
        await close()
    }
}
#endif
