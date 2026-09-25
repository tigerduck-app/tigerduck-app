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

    /// Reports an authentication rejection thrown by any command run through `use(_:)`.
    private let onAuthFailure: @MainActor () -> Void

    /// The idle-close wait, injectable so a test can drive the timer instead of waiting for it
    /// — the same seam `MailComposeViewModel` takes for its sent-copy dedupe delay. Nothing in
    /// this type's tests then depends on wall-clock scheduling.
    private let sleep: @Sendable (Duration) async -> Void

    /// Bumped by every sign-out. A client opened under an earlier value belongs to a student who
    /// is no longer signed in, so `resolveClient` never hands one out.
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
        // Registered here, before anything can use the session, and delivered synchronously
        // (`queue: nil`) on the main actor `MailAccountManager.logout()` posts from — so no
        // sign-out can land between two looks and be missed.
        signOutObserver = signOutEvents.addObserver(forName: MailAccountManager.didSignOut, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidateForSignOut() }
        }
    }

    deinit {
        if let signOutObserver { signOutEvents.removeObserver(signOutObserver) }
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

    /// §7.4's choke point reaches everything the page does, not only the sign-in it opened the
    /// connection with. SMTP `AUTH LOGIN` happens inside a `use(_:)` body and never goes near
    /// `MailAccountManager.openSession()`, and so does the held connection's own relogin — both
    /// used to leave `authFailed` unset, so the next tap sent the rejected password again. NTUST
    /// locks the account (and its Wi-Fi) after repeated failures, so every layer reports here.
    private func reportIfAuthenticationRejected(_ error: any Error) {
        guard (error as? MailClientError) == .authenticationFailed else { return }
        reportAuthenticationRejection()
    }

    /// Reports a rejected password a `use(_:)` body caught and deliberately did not rethrow.
    ///
    /// `use(_:)` only hears about an authentication rejection that travels as a thrown error, and
    /// one step of the page's work is best-effort by design: filing the sent copy must never fail
    /// a send that already succeeded (`SentCopyFiler`), so its `.authenticationFailed` is caught
    /// and turned into an outcome. §7.4 still has to hear about it — NTUST locks the account (and
    /// its Wi-Fi) after repeated failures — so that caller reports it here instead, reaching the
    /// same choke point a thrown one would have. Nothing else about `use(_:)`'s error path is
    /// skipped by doing so: an authentication failure never drops the connection either way
    /// (`dropsConnection`).
    func reportAuthenticationRejection() {
        onAuthFailure()
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

    /// Closes the connection the moment its student signs out, instead of leaving it for the
    /// idle timer.
    ///
    /// The timer is not enough: `use(_:)` cancels it and `resolveClient` reuses a held client
    /// as-is, and the client carries the credentials it logged in with. So a different student
    /// signing in within the idle window, and opening the mail tab, would be handed the previous
    /// student's session — their mailbox on screen, and a compose that sends *as them*.
    ///
    /// Synchronous so it completes inside the sign-out itself; the `LOGOUT` round trip runs
    /// after. A call still in flight keeps the client it already has, and finishes against it.
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
        if let stale { Task { await stale.logout() } }
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

    /// An open that a sign-out overtook is thrown away rather than adopted: the connection it
    /// made was logged in with the credentials of whoever was signed in when it started.
    private func resolveClient() async throws -> any MailClient {
        if let client { return client }
        let epoch = signOutEpoch
        if let opening {
            let opened = try await opening.value
            // Whoever started that open closes it; this caller only must not use it.
            guard epoch == signOutEpoch else { throw CancellationError() }
            return opened
        }
        let task = Task { try await open() }
        opening = task
        // Only this epoch's own open is cleared: after a sign-out, `opening` may already be a
        // newer call's, made for the next student.
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
