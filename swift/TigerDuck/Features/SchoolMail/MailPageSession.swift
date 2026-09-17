#if os(iOS)
import Foundation

/// The mail page's single IMAP connection (design doc §8.2): opened on first use, shared
/// by the list and the open message, closed ~30 s after the page goes away.
///
/// Callers do their server work through `use(_:)`, which counts the whole call as in flight
/// for as long as its body runs — so the idle-close timer can never act mid-command — and
/// drops the connection on a network or certificate error so the next call reconnects.
/// `client()` is kept only for a caller with no single async body to hand `use`; every other
/// caller (`MailListViewModel` included) goes through `use(_:)`.
@MainActor
final class MailPageSession {
    private let open: () async throws -> any MailClient
    private let idleClose: Duration
    private var client: (any MailClient)?
    private var opening: Task<any MailClient, Error>?
    private var closeTask: Task<Void, Never>?
    /// Bumped every time a close is armed or cancelled, so a close task that fires after its
    /// own arming was superseded can tell it's stale and do nothing — belt and suspenders
    /// alongside `Task.cancel()`, which a `Task.sleep` can race past by a tick.
    private var closeGeneration = 0
    /// Number of `use(_:)` bodies currently running. The idle-close timer only ever fires
    /// while this is zero.
    private var inFlight = 0
    /// True from `releaseSoon()` until the next `client()`/`use(_:)` call (or an actual
    /// close) cancels it. A `use(_:)` that ends while this is still true re-arms the close
    /// it had to defer.
    private var isReleased = false

    /// `nonisolated` so a `@MainActor` caller's own default-parameter value (e.g.
    /// `MailListViewModel`'s `session: MailPageSession = MailPageSession()`) can construct one
    /// without hopping actors — default-argument expressions are evaluated outside the
    /// enclosing declaration's isolation, so a MainActor-isolated init can't be called from
    /// one. Safe here because the body only assigns stored properties.
    nonisolated init(
        idleClose: Duration = .seconds(MailConstants.connectionIdleClose),
        open: @escaping () async throws -> any MailClient = { try await MailAccountManager.shared.openSession() }
    ) {
        self.idleClose = idleClose
        self.open = open
    }

    /// Obtains the session's client without counting it as in flight. Prefer `use(_:)`,
    /// which wraps a whole operation so the idle-close timer can't fire in the middle of it;
    /// call this directly only when there's no single async body to hand it.
    func client() async throws -> any MailClient {
        cancelClose()
        return try await resolveClient()
    }

    /// Runs `body` with the session's client, counting the whole call as in flight so the
    /// idle-close timer can't act until it's done. Drops the connection first on a network
    /// or certificate error, so the next call reconnects; a `searchUnsupported`,
    /// `folderChanged` or other protocol error leaves the connection in place.
    func use<T>(_ body: (any MailClient) async throws -> T) async throws -> T {
        cancelClose()
        inFlight += 1
        defer {
            inFlight -= 1
            if inFlight == 0, isReleased { armClose() }
        }
        let client = try await resolveClient()
        do {
            return try await body(client)
        } catch {
            if Self.dropsConnection(error) { await close() }
            throw error
        }
    }

    /// Arms the ~30 s close. Deferred while a `use(_:)` is still in flight — its `defer`
    /// re-arms this once it finishes.
    func releaseSoon() {
        isReleased = true
        if inFlight == 0 { armClose() }
    }

    /// Drops the connection — also called after an error, so the next call reconnects.
    func close() async {
        closeTask?.cancel()
        closeTask = nil
        closeGeneration += 1
        isReleased = false
        let current = client
        client = nil
        await current?.logout()
    }

    // MARK: Internals

    private func resolveClient() async throws -> any MailClient {
        if let client { return client }
        if let opening { return try await opening.value }
        let task = Task { try await open() }
        opening = task
        defer { opening = nil }
        let opened = try await task.value
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
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.fireClose(generation: generation)
        }
    }

    /// Only closes if nothing raced this timer: the generation it was armed with is still
    /// current (no cancel/re-arm happened since) and no `use(_:)` is in flight.
    private func fireClose(generation: Int) async {
        guard generation == closeGeneration, inFlight == 0 else { return }
        await close()
    }

    /// Mirrors `LiveMailClient.closesConnectionOnFailure`: only a network or certificate
    /// failure means the connection itself is dead. Every other `MailClientError` (including
    /// `searchUnsupported` and `folderChanged`) is the server saying no to one command, not a
    /// broken pipe, so the connection is kept for the next call.
    private static func dropsConnection(_ error: any Error) -> Bool {
        guard let mailError = error as? MailClientError else { return false }
        switch mailError {
        case .unreachable, .certificateRejected: return true
        case .authenticationFailed, .serverBusy, .searchUnsupported, .folderChanged, .protocolError: return false
        }
    }
}
#endif
