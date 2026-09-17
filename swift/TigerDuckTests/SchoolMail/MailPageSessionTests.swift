#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

/// Controller addition (2026-09-16 dispatch): `MailPageSession` must never close the
/// connection while a `use(_:)` command is in flight, a stale close timer must never act,
/// and a network/certificate error must drop the connection so the next call reconnects —
/// but only once every concurrent `use(_:)` is done with it (fix round 1).
///
/// Nothing here waits on a clock. An in-flight `use(_:)` is parked inside the client on
/// `FakeMailClient`'s command gate, and the idle-close timer is the injected `sleep:` below,
/// which the test fires by hand — so "the delay has passed" and "the call is still in flight"
/// are facts the test establishes rather than margins it hopes for. These two tests raced
/// 300 ms of sleeps against a 350 ms body before, and flaked accordingly.
@MainActor
struct MailPageSessionTests {
    private static let idleClose: Duration = .milliseconds(200)

    /// Stands in for the idle-close `Task.sleep`. Each call reports that the timer is armed and
    /// then suspends until the test fires it.
    private actor CloseTimer {
        private var sleepers: [CheckedContinuation<Void, Never>] = []
        private var armings = 0
        private var armWaiters: [CheckedContinuation<Void, Never>] = []

        /// One armed idle-close wait.
        func sleep() async {
            armings += 1
            for waiter in armWaiters { waiter.resume() }
            armWaiters = []
            await withCheckedContinuation { sleepers.append($0) }
        }

        /// Returns once the session has armed a close at least `count` times.
        func waitUntilArmed(atLeast count: Int = 1) async {
            while armings < count {
                await withCheckedContinuation { armWaiters.append($0) }
            }
        }

        var armedCount: Int { armings }

        /// Lets every armed timer's wait finish, as if the idle delay had elapsed.
        func fire() {
            let waiting = sleepers
            sleepers = []
            for sleeper in waiting { sleeper.resume() }
        }
    }

    @Test func closeIsDeferredWhileAUseIsInFlightAndHappensAfterItEnds() async throws {
        let fake = FakeMailClient(folders: ["INBOX": []])
        let timer = CloseTimer()
        let session = MailPageSession(idleClose: Self.idleClose, open: { fake }, sleep: { _ in await timer.sleep() })
        _ = try await session.use { _ in }

        await fake.update { $0.hold("status") }
        let useTask = Task {
            try await session.use { client in _ = try await client.status(folder: "INBOX") }
        }
        await fake.waitForArrival("status") // the use really is in flight, not merely spawned

        session.releaseSoon() // requested while that use is still in flight
        // Nothing may even be armed yet: an in-flight call defers the close entirely.
        #expect(await timer.armedCount == 0)
        #expect(await fake.calls.contains("logout") == false)

        await fake.release("status")
        _ = try await useTask.value // the use is done; the deferred close is armed now

        await timer.waitUntilArmed()
        await timer.fire() // the whole idle delay, with no clock
        await fake.waitForArrival("logout")
        #expect(await fake.calls.contains("logout"))
    }

    @Test func aStaleTimerDoesNothing() async throws {
        let fake = FakeMailClient(folders: ["INBOX": []])
        let timer = CloseTimer()
        let session = MailPageSession(idleClose: Self.idleClose, open: { fake }, sleep: { _ in await timer.sleep() })
        _ = try await session.use { _ in }
        session.releaseSoon() // arms a close at generation N
        await timer.waitUntilArmed()
        _ = try await session.use { _ in } // cancels it and bumps the generation; nothing re-arms it

        // Fire the superseded timer anyway, exactly as a real `Task.sleep` that raced past its
        // own `cancel()` by a tick would: whichever of the cancellation check or the generation
        // guard catches it, no close may happen.
        await timer.fire()
        await Task.yield()
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

        await fake.update { $0.hold("status") }
        let longUseTask = Task {
            try await session.use { client in _ = try await client.status(folder: "INBOX") }
        }
        await fake.waitForArrival("status") // parked inside the client, genuinely in flight

        await #expect(throws: MailClientError.self) {
            try await session.use { _ in throw MailClientError.unreachable }
        }
        // The failing use has already returned, but the long one is still in flight — the
        // drop it asked for must be deferred, not acted on immediately.
        #expect(await fake.calls.contains("logout") == false)

        await fake.release("status")
        // `use` only returns once its own `endUse()` has run, and that is what performs the
        // deferred drop — so there is nothing left to wait for after this line.
        _ = try await longUseTask.value
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
