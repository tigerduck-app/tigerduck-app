#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

/// Controller addition (2026-09-16 dispatch): `MailPageSession` must never close the
/// connection while a `use(_:)` command is in flight, a stale close timer must never act,
/// and a network/certificate error must drop the connection so the next call reconnects —
/// but only once every concurrent `use(_:)` is done with it (fix round 1).
///
/// `idleClose` is a generous 200 ms in every test here, with margins at least 50 ms clear of
/// it in both directions, specifically so these don't flake under CI scheduling jitter the
/// way the original 10/15/25 ms margins did.
@MainActor
struct MailPageSessionTests {
    private static let idleClose: Duration = .milliseconds(200)

    @Test func closeIsDeferredWhileAUseIsInFlightAndHappensAfterItEnds() async throws {
        let fake = FakeMailClient(folders: ["INBOX": []])
        let session = MailPageSession(idleClose: Self.idleClose, open: { fake })
        _ = try await session.use { _ in }

        let useTask = Task {
            try await session.use { _ in try? await Task.sleep(for: .milliseconds(350)) }
        }
        try await Task.sleep(for: .milliseconds(20)) // let the use above actually start first
        session.releaseSoon() // requested while that use is still in flight

        // The idle-close delay (200 ms) has long since passed, but the use is still running —
        // the close must not have happened yet.
        try await Task.sleep(for: .milliseconds(280))
        #expect(await fake.calls.contains("logout") == false)

        _ = try await useTask.value // let the use finish
        try await Task.sleep(for: .milliseconds(280))
        #expect(await fake.calls.contains("logout"))
    }

    @Test func aStaleTimerDoesNothing() async throws {
        let fake = FakeMailClient(folders: ["INBOX": []])
        let session = MailPageSession(idleClose: Self.idleClose, open: { fake })
        _ = try await session.use { _ in }
        session.releaseSoon() // arms a close at generation N
        _ = try await session.use { _ in } // cancels it and bumps the generation; nothing re-arms it
        try await Task.sleep(for: .milliseconds(280))
        #expect(await fake.calls.contains("logout") == false)
    }

    @Test func aNetworkErrorDropsTheClient() async throws {
        var openCount = 0
        let fake = FakeMailClient(folders: ["INBOX": []])
        let session = MailPageSession(idleClose: .seconds(30), open: {
            openCount += 1
            return fake
        })
        _ = try await session.use { _ in }
        #expect(openCount == 1)
        await #expect(throws: MailClientError.self) {
            try await session.use { _ in throw MailClientError.unreachable }
        }
        #expect(await fake.calls.contains("logout"))
        _ = try await session.use { _ in }
        #expect(openCount == 2) // dropped, so the next call reopened
    }

    @Test func aProtocolErrorKeepsTheClient() async throws {
        var openCount = 0
        let fake = FakeMailClient(folders: ["INBOX": []])
        let session = MailPageSession(idleClose: .seconds(30), open: {
            openCount += 1
            return fake
        })
        _ = try await session.use { _ in }
        await #expect(throws: MailClientError.self) {
            try await session.use { _ in throw MailClientError.protocolError("x") }
        }
        #expect(await fake.calls.contains("logout") == false)
        _ = try await session.use { _ in }
        #expect(openCount == 1) // kept, so the next call reused it
    }

    /// Fix round 1: a network/certificate error from one `use(_:)` must not yank the
    /// connection out from under a *different* `use(_:)` still running concurrently on it —
    /// the drop has to wait until every in-flight call is done.
    @Test func anErrorPathDropWaitsForEveryOtherInFlightUseBeforeClosing() async throws {
        let fake = FakeMailClient(folders: ["INBOX": []])
        let session = MailPageSession(idleClose: .seconds(30), open: { fake })
        _ = try await session.use { _ in }

        let longUseTask = Task {
            try await session.use { _ in try? await Task.sleep(for: .milliseconds(300)) }
        }
        try await Task.sleep(for: .milliseconds(50)) // let the long use actually start first

        await #expect(throws: MailClientError.self) {
            try await session.use { _ in throw MailClientError.unreachable }
        }
        // The failing use has already returned, but the long one is still in flight — the
        // drop it asked for must be deferred, not acted on immediately.
        #expect(await fake.calls.contains("logout") == false)

        _ = try await longUseTask.value // let the long use finish
        try await Task.sleep(for: .milliseconds(80)) // give the now-deferred drop a moment to run
        #expect(await fake.calls.contains("logout"))
    }

    /// §7.4: a rejected password is never sent again. `MailAccountManager.openSession()` is the
    /// documented choke point for the IMAP sign-in, but SMTP `AUTH LOGIN` happens inside a
    /// `use(_:)` body and never goes near it — so the session reports an authentication rejection
    /// from *any* layer, not just the one it opened the connection with.
    @Test func anAuthenticationRejectionFromInsideAUseIsReported() async throws {
        let fake = FakeMailClient(folders: ["INBOX": []])
        var failures = 0
        let session = MailPageSession(idleClose: .seconds(30), open: { fake }, onAuthFailure: { failures += 1 })
        await #expect(throws: MailClientError.self) {
            try await session.use { _ in throw MailClientError.authenticationFailed }
        }
        #expect(failures == 1)
    }

    @Test func anOrdinaryFailureIsNotReportedAsAnAuthenticationRejection() async throws {
        let fake = FakeMailClient(folders: ["INBOX": []])
        var failures = 0
        let session = MailPageSession(idleClose: .seconds(30), open: { fake }, onAuthFailure: { failures += 1 })
        await #expect(throws: MailClientError.self) {
            try await session.use { _ in throw MailClientError.serverBusy }
        }
        #expect(failures == 0)
    }
}
#endif
