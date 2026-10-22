#if os(iOS)
import Foundation

@MainActor
final class MailPageSession {
    private let open: () async throws -> any MailClient
    private let idleClose: Duration
    private var client: (any MailClient)?
    private var opening: Task<any MailClient, Error>?
    private var closeTask: Task<Void, Never>?
    private var closeGeneration = 0
    private var inFlight = 0
    private var isReleased = false
    private var pendingDrop = false

    private let onAuthFailure: @MainActor () -> Void

    private let sleep: @Sendable (Duration) async -> Void

    private var signOutEpoch = 0
    nonisolated(unsafe) private var signOutObserver: (any NSObjectProtocol)?
    private let signOutEvents: NotificationCenter

    init(
        idleClose: Duration = .seconds(MailConstants.connectionIdleClose),
        open: @escaping () async throws -> any MailClient = { try await MailAccountManager.shared.openSession() },
        onAuthFailure: @escaping @MainActor () -> Void = { MailAccountManager.shared.handleAuthFailure() },
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        signOutEvents: NotificationCenter = .default
    ) {
        self.idleClose = idleClose
        self.open = open
        self.onAuthFailure = onAuthFailure
        self.sleep = sleep
        self.signOutEvents = signOutEvents
        signOutObserver = signOutEvents.addObserver(forName: MailAccountManager.didSignOut, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidateForSignOut() }
        }
    }

    deinit {
        if let signOutObserver { signOutEvents.removeObserver(signOutObserver) }
    }

    func use<T>(_ body: (any MailClient) async throws -> T) async throws -> T {
        cancelClose()
        inFlight += 1
        let client: any MailClient
        do {
            client = try await resolveClient()
        } catch {
            reportIfAuthenticationRejected(error)
            await endUse()
            throw error
        }
        do {
            let result = try await body(client)
            await endUse()
            return result
        } catch {
            if Self.dropsConnection(error) { pendingDrop = true }
            reportIfAuthenticationRejected(error)
            await endUse()
            throw error
        }
    }

    private func reportIfAuthenticationRejected(_ error: any Error) {
        guard (error as? MailClientError) == .authenticationFailed else { return }
        reportAuthenticationRejection()
    }

    func reportAuthenticationRejection() {
        onAuthFailure()
    }

    func releaseSoon() {
        isReleased = true
        if inFlight == 0 { armClose() }
    }

    func close() async {
        closeTask?.cancel()
        closeTask = nil
        closeGeneration += 1
        isReleased = false
        pendingDrop = false
        let current = client
        client = nil
        await current?.logout()
    }

    func invalidateForSignOut() {
        signOutEpoch += 1
        closeTask?.cancel()
        closeTask = nil
        closeGeneration += 1
        isReleased = false
        pendingDrop = false
        opening = nil
        let stale = client
        client = nil
    /// The choke point that keeps a rejected password from being sent again covers everything
    /// the page does, not only the sign-in that opened the connection. SMTP `AUTH LOGIN` and the
    /// held connection's own relogin run inside a `use(_:)` body, never through
    /// `MailAccountManager.openSession()`, so without this they would leave `authFailed` unset
    /// and the next tap would send the rejected password again. NTUST locks the account (and
    /// its Wi-Fi) after repeated failures, so every layer reports here.
        if let stale { Task { await stale.logout() } }
    }

    private func endUse() async {
        inFlight -= 1
    /// Reports a rejected password a `use(_:)` body caught and did not rethrow.
    ///
    /// `use(_:)` only hears about a rejection thrown as an error, and filing the sent copy is
    /// best-effort: it must never fail a send that already succeeded (`SentCopyFiler`), so its
    /// `.authenticationFailed` is caught and turned into an outcome. NTUST locks the account (and
    /// its Wi-Fi) after repeated failures, so that caller reports here, reaching the same choke
    /// point a thrown error would. Nothing else in `use(_:)`'s error path is skipped: an
    /// authentication failure never drops the connection either way (`dropsConnection`).
        guard inFlight == 0 else { return }
        if pendingDrop {
            await close()
        } else if isReleased {
            armClose()
        }
    }

    private func resolveClient() async throws -> any MailClient {
        if let client { return client }
        let epoch = signOutEpoch
        if let opening {
            let opened = try await opening.value
            guard epoch == signOutEpoch else { throw CancellationError() }
            return opened
        }
        let task = Task { try await open() }
        opening = task
        defer { if epoch == signOutEpoch { opening = nil } }
        let opened = try await task.value
        guard epoch == signOutEpoch else {
            await opened.logout()
            throw CancellationError()
        }
        client = opened
        return opened
    }

    private func cancelClose() {
        closeTask?.cancel()
        closeTask = nil
        closeGeneration += 1
        isReleased = false
    }

    private func armClose() {
        closeTask?.cancel()
        closeGeneration += 1
        let generation = closeGeneration
        let delay = idleClose
        let sleep = self.sleep
        closeTask = Task { [weak self] in
            await sleep(delay)
            guard !Task.isCancelled else { return }
            await self?.fireClose(generation: generation)
        }
    }

    private func fireClose(generation: Int) async {
        guard generation == closeGeneration, inFlight == 0 else { return }
        await close()
    }

    private static func dropsConnection(_ error: any Error) -> Bool {
        guard let mailError = error as? MailClientError else { return false }
        switch mailError {
        case .unreachable, .certificateRejected: return true
        case .authenticationFailed, .serverBusy, .searchUnsupported, .folderChanged, .sendUnconfirmed,
             .protocolError: return false
        }
    }
}
#endif
