#if os(iOS)
import Foundation

/// The mail page's single IMAP connection (design doc §8.2): opened on first use, shared
/// by the list and the open message, closed ~30 s after the page goes away.
///
/// Callers do their server work through `use(_:)`, which counts the whole call as in flight
/// for as long as its body runs — so the idle-close timer can never act mid-command, and a
/// network/certificate error can only close the connection once every other concurrent
/// `use(_:)` has also finished — and drops the connection on such an error so the next call
/// reconnects. There's no bare `client()`: every caller (`MailListViewModel` included) goes
/// through `use(_:)`, which is also what keeps `inFlight` an accurate count of every call that
/// currently holds (or is still resolving) a client.
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
    /// Number of `use(_:)` bodies currently running (including the time spent resolving the
    /// client, before `body` even starts). The idle-close timer only ever fires while this is
    /// zero, and a network/certificate error only closes once this reaches zero.
    private var inFlight = 0
    /// True from `releaseSoon()` until the next `use(_:)` call (or an actual close) cancels
    /// it. A `use(_:)` that ends while this is still true re-arms the close it had to defer.
    private var isReleased = false
    /// Set when a `use(_:)` body throws a network/certificate error while another `use(_:)`
    /// is still in flight on the same connection: closing right away would pull the
    /// connection out from under that other call, so the drop is deferred until `inFlight`
    /// reaches zero instead.
    private var pendingDrop = false

    init(
        idleClose: Duration = .seconds(MailConstants.connectionIdleClose),
        open: @escaping () async throws -> any MailClient = { try await MailAccountManager.shared.openSession() }
    ) {
        self.idleClose = idleClose
        self.open = open
    }

    /// Runs `body` with the session's client, counting the whole call — including resolving
    /// the client — as in flight so the idle-close timer can't act until every concurrent
    /// `use(_:)` is done. A network or certificate error marks the connection for dropping;
    /// the drop itself waits until `inFlight` reaches zero, so it can never yank the
    /// connection out from under a sibling call still in progress. A `searchUnsupported`,
    /// `folderChanged` or other protocol error leaves the connection in place.
    func use<T>(_ body: (any MailClient) async throws -> T) async throws -> T {
        cancelClose()
        inFlight += 1
        let client: any MailClient
        do {
            client = try await resolveClient()
        } catch {
            await endUse()
            throw error
        }
        do {
            let result = try await body(client)
            await endUse()
            return result
        } catch {
            if Self.dropsConnection(error) { pendingDrop = true }
            await endUse()
            throw error
        }
    }

    /// Arms the ~30 s close. Deferred while a `use(_:)` is still in flight — its `defer`
    /// re-arms this once it finishes.
    func releaseSoon() {
        isReleased = true
        if inFlight == 0 { armClose() }
    }

    /// Drops the connection — also called after every `use(_:)` finishes once `inFlight`
    /// reaches zero, if any of them marked the connection for dropping.
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

    // MARK: Internals

    /// Ends one `use(_:)` call's accounting. Once `inFlight` reaches zero, a connection some
    /// concurrent call marked for dropping is closed (taking priority over a deferred
    /// `releaseSoon()`, since there's no point re-arming a close for a connection that's
    /// about to be dropped anyway); otherwise a deferred `releaseSoon()` is re-armed.
    private func endUse() async {
        inFlight -= 1
        guard inFlight == 0 else { return }
        if pendingDrop {
            await close()
        } else if isReleased {
            armClose()
        }
    }

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
