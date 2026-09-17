#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

/// Controller addition (2026-09-16 dispatch): `MailPageSession` must never close the
/// connection while a `use(_:)` command is in flight, a stale close timer must never act,
/// and a network/certificate error must drop the connection so the next call reconnects.
@MainActor
struct MailPageSessionTests {
    @Test func closeIsDeferredWhileAUseIsInFlightAndHappensAfterItEnds() async throws {
        let fake = FakeMailClient(folders: ["INBOX": []])
        let session = MailPageSession(idleClose: .milliseconds(15), open: { fake })
        _ = try await session.client()

        let useTask = Task {
            try await session.use { _ in try? await Task.sleep(for: .milliseconds(70)) }
        }
        try await Task.sleep(for: .milliseconds(10)) // let the use above actually start first
        session.releaseSoon() // requested while that use is still in flight

        // The idle-close delay (15 ms) has long since passed, but the use is still running —
        // the close must not have happened yet.
        try await Task.sleep(for: .milliseconds(40))
        #expect(await fake.calls.contains("logout") == false)

        _ = try await useTask.value // let the use finish
        try await Task.sleep(for: .milliseconds(40))
        #expect(await fake.calls.contains("logout"))
    }

    @Test func aStaleTimerDoesNothing() async throws {
        let fake = FakeMailClient(folders: ["INBOX": []])
        let session = MailPageSession(idleClose: .milliseconds(15), open: { fake })
        _ = try await session.client()
        session.releaseSoon() // arms a close at generation N
        _ = try await session.client() // cancels it and bumps the generation; nothing re-arms it
        try await Task.sleep(for: .milliseconds(60))
        #expect(await fake.calls.contains("logout") == false)
    }

    @Test func aNetworkErrorDropsTheClient() async throws {
        var openCount = 0
        let fake = FakeMailClient(folders: ["INBOX": []])
        let session = MailPageSession(idleClose: .seconds(30), open: {
            openCount += 1
            return fake
        })
        _ = try await session.client()
        #expect(openCount == 1)
        await #expect(throws: MailClientError.self) {
            try await session.use { _ in throw MailClientError.unreachable }
        }
        #expect(await fake.calls.contains("logout"))
        _ = try await session.client()
        #expect(openCount == 2) // dropped, so the next call reopened
    }

    @Test func aProtocolErrorKeepsTheClient() async throws {
        var openCount = 0
        let fake = FakeMailClient(folders: ["INBOX": []])
        let session = MailPageSession(idleClose: .seconds(30), open: {
            openCount += 1
            return fake
        })
        _ = try await session.client()
        await #expect(throws: MailClientError.self) {
            try await session.use { _ in throw MailClientError.protocolError("x") }
        }
        #expect(await fake.calls.contains("logout") == false)
        _ = try await session.client()
        #expect(openCount == 1) // kept, so the next call reused it
    }
}
#endif
