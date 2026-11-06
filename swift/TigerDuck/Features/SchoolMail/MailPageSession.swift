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
    // NTUST locks the account and its Wi-Fi after repeated failed sign-ins, so every rejection a
    // use sees, thrown or caught, reaches this.
    private let onAuthFailure: @MainActor (SignIn) -> Void
    let account: AccountSession
    private var signOutListener: MailNotificationListener?

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
        signOutListener = MailNotificationListener(center: signOutEvents, name: MailAccountManager.didSignOut) { [weak self] in self?.invalidateForSignOut() }
    }

    func use<T>(for signIn: SignIn? = nil, _ body: (any MailClient) async throws -> T) async throws -> T {
        try await run(for: signIn, body) { _, _ in }
    }

    func use<T: MailCaughtRejection>(
        for signIn: SignIn? = nil, _ body: (any MailClient) async throws -> T
    ) async throws -> T {
        try await run(for: signIn, body) { result, signIn in
            if result.rejectedPassword { reportAuthenticationRejection(for: signIn) }
        }
    }

    private func run<T>(
        for given: SignIn?, _ body: (any MailClient) async throws -> T, then inspect: (T, SignIn) -> Void
    ) async throws -> T {
        let signIn: SignIn
        if let given { signIn = given } else { signIn = await account.startingSignIn }
        guard signIn.isCurrent else { throw CancellationError() }
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
            inspect(result, signIn)
            await endUse()
            return result
        } catch {
            if MailErrorClass(error)?.closesConnection == true { pendingDrop = true }
            reportIfAuthenticationRejected(error, for: signIn)
            await endUse()
            throw error
        }
    }

    private func reportIfAuthenticationRejected(_ error: any Error, for signIn: SignIn) {
        guard (error as? MailClientError) == .authenticationFailed else { return }
        reportAuthenticationRejection(for: signIn)
    }

    private func reportAuthenticationRejection(for signIn: SignIn) {
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
