#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct MailPageSessionTests {
    private static let idleClose: Duration = .milliseconds(200)

    @Test func closeIsDeferredWhileAUseIsInFlightAndHappensAfterItEnds() async throws {
        let fake = FakeMailClient(folders: ["INBOX": []])
        let timer = ManualSleeper()
        let session = MailPageSession(idleClose: Self.idleClose, open: { fake }, sleep: { await timer.sleep(for: $0) })
        _ = try await session.use { _ in }

        await fake.update { $0.hold("status") }
        let useTask = Task {
            try await session.use { client in _ = try await client.status(folder: "INBOX") }
        }
        await fake.waitForArrival("status")

        session.releaseSoon()
        #expect(await timer.armedCount == 0)
        #expect(await fake.calls.contains("logout") == false)

        await fake.release("status")
        _ = try await useTask.value

        try await timer.waitUntilArmed()
        #expect(await timer.requestedDurations == [Self.idleClose])
        await timer.fire()
        await fake.waitForArrival("logout")
        #expect(await fake.calls.contains("logout"))
    }

    @Test func aStaleTimerDoesNothing() async throws {
        let fake = FakeMailClient(folders: ["INBOX": []])
        let timer = ManualSleeper()
        let session = MailPageSession(idleClose: Self.idleClose, open: { fake }, sleep: { await timer.sleep(for: $0) })
        _ = try await session.use { _ in }
        session.releaseSoon()
        try await timer.waitUntilArmed()
        _ = try await session.use { _ in }

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
        #expect(openCount == 2)
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
        #expect(openCount == 1)
    }

    @Test func anErrorPathDropWaitsForEveryOtherInFlightUseBeforeClosing() async throws {
        let fake = FakeMailClient(folders: ["INBOX": []])
        let session = MailPageSession(idleClose: .seconds(30), open: { fake })
        _ = try await session.use { _ in }

        await fake.update { $0.hold("status") }
        let longUseTask = Task {
            try await session.use { client in _ = try await client.status(folder: "INBOX") }
        }
        await fake.waitForArrival("status")

        await #expect(throws: MailClientError.self) {
            try await session.use { _ in throw MailClientError.unreachable }
        }
        #expect(await fake.calls.contains("logout") == false)

        await fake.release("status")
        _ = try await longUseTask.value
        #expect(await fake.calls.contains("logout"))
    }

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

    private final class Opener {
        let first: FakeMailClient
        let second: FakeMailClient
        var count = 0
        init(first: FakeMailClient, second: FakeMailClient) {
            self.first = first
            self.second = second
        }
        func open() async throws -> any MailClient {
            count += 1
            if count == 1 {
                try await first.login(studentID: "B10000000", password: "pw")
                return first
            }
            return second
        }
    }

    @Test func aSignOutClosesTheHeldConnectionAtOnce() async throws {
        let center = NotificationCenter()
        let opener = Opener(first: FakeMailClient(folders: ["INBOX": []]), second: FakeMailClient(folders: ["INBOX": []]))
        let session = MailPageSession(idleClose: .seconds(30), open: { try await opener.open() }, signOutEvents: center)
        _ = try await session.use { _ in }

        center.post(name: MailAccountManager.didSignOut, object: nil)
        await opener.first.waitForArrival("logout")
        #expect(await opener.first.calls.contains("logout"))

        let next = try await session.use { $0 }
        #expect(next === opener.second)
        #expect(opener.count == 2)
    }

    @Test func aSignOutThroughTheAccountManagerReachesTheSession() async throws {
        let center = NotificationCenter()
        let fake = FakeMailClient(folders: ["INBOX": []])
        let manager = MailAccountManager(
            prefs: InMemoryMailPreferences(),
            credentials: MailCredentialStore(storage: InMemoryMailSecretStorage()),
            cache: SchoolMailTestDoubles.temporaryCache(),
            signOutEvents: center
        )
        let session = MailPageSession(idleClose: .seconds(30), open: { fake }, signOutEvents: center)
        _ = try await session.use { _ in }
        manager.logout()
        await fake.waitForArrival("logout")
        #expect(await fake.calls.contains("logout"))
    }

    @Test func anOpenOvertakenByASignOutIsClosedNotAdopted() async throws {
        let center = NotificationCenter()
        let opener = Opener(first: FakeMailClient(folders: ["INBOX": []]), second: FakeMailClient(folders: ["INBOX": []]))
        let session = MailPageSession(idleClose: .seconds(30), open: { try await opener.open() }, signOutEvents: center)
        await opener.first.hold("login")
        let use = Task { try await session.use { $0 } }
        await opener.first.waitForArrival("login")

        center.post(name: MailAccountManager.didSignOut, object: nil)
        await opener.first.release("login")

        await #expect(throws: CancellationError.self) { _ = try await use.value }
        #expect(await opener.first.calls.contains("logout"))
        let next = try await session.use { $0 }
        #expect(next === opener.second)
    }

    @Test func aSignOutElsewhereLeavesTheSessionAlone() async throws {
        let fake = FakeMailClient(folders: ["INBOX": []])
        let session = MailPageSession(idleClose: .seconds(30), open: { fake }, signOutEvents: NotificationCenter())
        _ = try await session.use { _ in }
        NotificationCenter().post(name: MailAccountManager.didSignOut, object: nil)
        await Task.yield()
        #expect(await fake.calls.contains("logout") == false)
    }
}
#endif
