#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct MailAccountManagerTests {
    final class Hooks {
        var signedIn = 0, signedOut = 0, authFailed = 0, enabled = 0, disabled = 0
        var demoFlags: [Bool] = []
    }

    struct Harness {
        let manager: MailAccountManager
        let prefs: InMemoryMailPreferences
        let secrets: InMemoryMailSecretStorage
        let cache: MailCache
        let fake: FakeMailClient
        let hooks: Hooks
    }

    static func harness(prefs: InMemoryMailPreferences = InMemoryMailPreferences()) -> Harness {
        let secrets = InMemoryMailSecretStorage()
        let cache = SchoolMailTestDoubles.temporaryCache()
        let fake = FakeMailClient(folders: [
            "INBOX": [FakeMailClient.message(uid: 1), FakeMailClient.message(uid: 2), FakeMailClient.message(uid: 3)],
            MailFolderRole.sent.imapName: [FakeMailClient.message(uid: 1, from: "b10000000@mail.ntust.edu.tw", name: "王大明")],
        ])
        let hooks = Hooks()
        let manager = MailAccountManager(
            prefs: prefs,
            credentials: MailCredentialStore(storage: secrets),
            cache: cache,
            isDemoLogin: { id, password in id == "B99999999" && password == "tigerduck-review" },
            makeClient: { demo in
                hooks.demoFlags.append(demo)
                return fake
            }
        )
        manager.onSignedIn = { hooks.signedIn += 1 }
        manager.onSignedOut = { hooks.signedOut += 1 }
        manager.onAuthFailed = { hooks.authFailed += 1 }
        manager.onNotificationsEnabled = { hooks.enabled += 1 }
        manager.onNotificationsDisabled = { hooks.disabled += 1 }
        return Harness(manager: manager, prefs: prefs, secrets: secrets, cache: cache, fake: fake, hooks: hooks)
    }

    @Test func aSuccessfulLoginStoresEverythingAndSetsTheBaseline() async {
        let h = Self.harness()
        await h.manager.login(studentID: " b10000000 ", password: "pw")
        #expect(h.manager.studentID == "B10000000")
        #expect(h.manager.isLoggedIn)
        #expect(h.prefs.studentID == "B10000000")
        #expect(h.secrets.load(forKey: MailCredentialStore.passwordKey) == "pw")
        #expect(h.prefs.inboxUIDValidity == 1)
        #expect(h.prefs.inboxNextUID == 4)
        #expect(h.manager.displayName == "王大明")
        #expect(h.hooks.signedIn == 1)
        #expect(h.hooks.demoFlags == [false])
        #expect(await h.fake.calls.last == "logout")
    }

    @Test func aFailedLoginStoresNothing() async {
        let h = Self.harness()
        await h.fake.update { $0.loginError = .authenticationFailed }
        await h.manager.login(studentID: "B10000000", password: "wrong")
        #expect(h.manager.loginError == .credentials)
        #expect(!h.manager.isLoggedIn)
        #expect(h.prefs.studentID == nil)
        #expect(h.secrets.load(forKey: MailCredentialStore.passwordKey) == nil)
        #expect(h.hooks.signedIn == 0)
    }

    @Test(arguments: [
        (MailClientError.unreachable, MailAccountManager.LoginError.network),
        (.certificateRejected, .certificate),
        (.serverBusy, .busy),
        (.protocolError("x"), .generic),
    ])
    func loginErrorsHaveTheirOwnMessages(error: MailClientError, expected: MailAccountManager.LoginError) async {
        let h = Self.harness()
        await h.fake.update { $0.loginError = error }
        await h.manager.login(studentID: "B10000000", password: "pw")
        #expect(h.manager.loginError == expected)
    }

    @Test func demoCredentialsSelectTheDemoClient() async {
        let h = Self.harness()
        await h.manager.login(studentID: "B99999999", password: "tigerduck-review")
        #expect(h.hooks.demoFlags == [true])
        #expect(h.prefs.demoActive)
    }

    @Test func anExistingDisplayNameIsKept() async {
        let prefs = InMemoryMailPreferences()
        prefs.displayName = "Da-Ming"
        let h = Self.harness(prefs: prefs)
        await h.manager.login(studentID: "B10000000", password: "pw")
        #expect(h.manager.displayName == "Da-Ming")
    }

    @Test func aRejectedPasswordMarksAuthFailureOnce() async {
        let h = Self.harness()
        await h.manager.login(studentID: "B10000000", password: "pw")
        await h.fake.update { $0.acceptedPassword = "changed" }
        await #expect(throws: MailClientError.authenticationFailed) { _ = try await h.manager.openSession() }
        let loginCallsAfterFirstRejection = await h.fake.calls.filter { $0.hasPrefix("login") }.count
        await #expect(throws: MailClientError.authenticationFailed) { _ = try await h.manager.openSession() }
        #expect(h.manager.authFailed)
        #expect(h.prefs.authFailed)
        #expect(h.hooks.authFailed == 1)
        // Spec §7.4: a rejected password is never retried. The second `openSession()` throws
        // without creating a client or sending another LOGIN — the fake's login call count
        // must not grow past what the first rejection already left it at.
        #expect(await h.fake.calls.filter { $0.hasPrefix("login") }.count == loginCallsAfterFirstRejection)
    }

    @Test func aSuccessfulLoginAfterAnAuthFailureLetsOpenSessionLogInAgain() async throws {
        let h = Self.harness()
        await h.manager.login(studentID: "B10000000", password: "pw")
        await h.fake.update { $0.acceptedPassword = "changed" }
        await #expect(throws: MailClientError.authenticationFailed) { _ = try await h.manager.openSession() }
        #expect(h.manager.authFailed)
        let loginCallsAfterRejection = await h.fake.calls.filter { $0.hasPrefix("login") }.count

        // The user re-enters the (now correct) password: only a successful `login(...)` may
        // clear `authFailed`, and once it does, `openSession()` is allowed to send LOGIN again.
        await h.fake.update { $0.acceptedPassword = nil }
        await h.manager.login(studentID: "B10000000", password: "changed")
        #expect(!h.manager.authFailed)
        #expect(!h.prefs.authFailed)

        let client = try await h.manager.openSession()
        await client.logout()
        #expect(await h.fake.calls.filter { $0.hasPrefix("login") }.count > loginCallsAfterRejection)
    }

    @Test func aMissingPasswordIsNotAnAuthFailure() async {
        let prefs = InMemoryMailPreferences()
        prefs.studentID = "B10000000"
        let h = Self.harness(prefs: prefs)
        await #expect(throws: MailClientError.protocolError("credentials unavailable")) { _ = try await h.manager.openSession() }
        #expect(!h.manager.authFailed)
    }

    @Test func logoutClearsEverything() async throws {
        let h = Self.harness()
        await h.manager.login(studentID: "B10000000", password: "pw")
        h.cache.savePage(MailFolderPage(folder: "INBOX", uidValidity: 1, messageCount: 0, summaries: [], oldestLoadedSequence: nil))
        h.manager.logout()
        // `logout()` starts the cache wipe off the main actor (see `MailAccountManager`); wait
        // for that specific in-flight clear before asserting the cache is empty, instead of
        // racing it.
        await h.manager.pendingCacheClear?.value
        #expect(!h.manager.isLoggedIn)
        #expect(h.manager.displayName == nil)
        #expect(h.secrets.load(forKey: MailCredentialStore.passwordKey) == nil)
        #expect(h.prefs.studentID == nil)
        #expect(h.prefs.inboxNextUID == nil)
        #expect(h.cache.loadPage(folder: "INBOX") == nil)
        #expect(h.hooks.signedOut == 1)
    }

    /// Deviation from the brief (controller-directed): `logout()`'s cache wipe runs off the
    /// main actor in a detached task instead of inline, so a logout immediately followed by a
    /// login must not let the new session's state get written while the old logout's clear is
    /// still in flight — otherwise a slow clear finishing later could wipe the new session's
    /// freshly cached mail. `clearCache` here artificially outlasts a normal (near-instant)
    /// clear so the ordering is observable rather than a coin flip: if `login()` didn't await
    /// the pending clear, "loginDone" would be recorded almost immediately, before "clearEnd".
    @Test func loginWaitsForAPendingLogoutClearBeforeWritingNewSessionState() async {
        let secrets = InMemoryMailSecretStorage()
        let cache = SchoolMailTestDoubles.temporaryCache()
        let prefs = InMemoryMailPreferences()
        let fake = FakeMailClient(folders: ["INBOX": [FakeMailClient.message(uid: 1)]])
        let recorder = CacheClearOrderRecorder()
        let manager = MailAccountManager(
            prefs: prefs,
            credentials: MailCredentialStore(storage: secrets),
            cache: cache,
            isDemoLogin: { _, _ in false },
            makeClient: { _ in fake },
            clearCache: {
                await recorder.record("clearStart")
                try? await Task.sleep(for: .milliseconds(30))
                cache.clearAll()
                await recorder.record("clearEnd")
            }
        )

        manager.logout()
        await manager.login(studentID: "B10000000", password: "pw")
        await recorder.record("loginDone")

        #expect(await recorder.events == ["clearStart", "clearEnd", "loginDone"])
        #expect(prefs.studentID == "B10000000")
    }

    @Test func theNotificationToggleCallsItsHooksOnlyWhenSignedIn() async {
        let h = Self.harness()
        h.manager.notificationsEnabled = false
        #expect(h.hooks.disabled == 0)
        await h.manager.login(studentID: "B10000000", password: "pw")
        h.manager.notificationsEnabled = true
        h.manager.notificationsEnabled = false
        #expect(h.hooks.enabled == 1)
        #expect(h.hooks.disabled == 1)
        #expect(h.prefs.notificationsEnabled == false)
    }

    @Test func theBundledDemoMailboxWorksOffline() async throws {
        let fixture = try #require(MailDemoFixture.load(from: .main))
        let demo = DemoMailClient(fixture: fixture)
        await #expect(throws: MailClientError.authenticationFailed) { try await demo.login(studentID: "B99999999", password: "nope") }
        try await demo.login(studentID: "b99999999", password: "tigerduck-review")
        let page = try await demo.page(folder: "INBOX", olderThanSequence: nil, pageSize: 50)
        #expect(page.summaries.map(\.uid) == [4, 3, 2, 1])
        let bait = try await demo.detail(folder: "INBOX", uid: 1)
        #expect(bait.htmlBody?.contains("mailbox-quota.example") == true)
        let withAttachment = try await demo.detail(folder: "INBOX", uid: 3)
        let part = try #require(withAttachment.attachments.first)
        #expect(try await demo.attachment(folder: "INBOX", uid: 3, part: part) == Data(base64Encoded: "JVBERi0xLjQK"))
        #expect(!(try await demo.rawSource(folder: "INBOX", uid: 4)).isEmpty)
    }
}

/// Collects events from concurrent tasks without a data race — used only to assert ordering in
/// `loginWaitsForAPendingLogoutClearBeforeWritingNewSessionState` above. Mirrors
/// `AsyncSerialLockTests`'s `LockOrderRecorder`.
private actor CacheClearOrderRecorder {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}
#endif
