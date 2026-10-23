import Foundation
import Testing
@testable import TigerDuck

/// Each school seam left at its default stops at `SchoolNetworkGuard`, which names it and sends
/// nothing. Serialized: `capturing` takes what the guard stops from every test running meanwhile.
@Suite("School network guard", .serialized)
@MainActor
struct SchoolNetworkGuardTests {
    @Test("every configuration the app builds its sessions from starts with the guard")
    func sessionsStartWithTheGuard() {
        let configurations = [
            URLSessionConfiguration.default,
            URLSessionConfiguration.ephemeral,
            MoodleTokenService.harvestConfiguration(),
            NTUSTSessionManager.shared.session.configuration,
            MoodleWebserviceClient.session.configuration,
            SemesterCatalog.session.configuration,
        ]

        for configuration in configurations {
            #expect(configuration.protocolClasses?.first == SchoolNetworkGuard.self)
        }
    }

    @Test("the guard takes every NTUST host by name, whatever its TLS pins, and no other host")
    func schoolHostsByName() {
        func seam(_ host: String) -> String? {
            SchoolNetworkGuard.seam(of: URLRequest(url: URL(string: "https://\(host)/")!))
        }

        for host in ["www.ntust.edu.tw", "NTUST.EDU.TW.", "api.lib.ntust.edu.tw", "mail.ntust.edu.tw"] {
            #expect(seam(host) != nil, "\(host)")
        }
        for host in ["settings-stub.invalid", "ntust.edu.tw.example.com", "notntust.edu.tw"] {
            #expect(seam(host) == nil, "\(host)")
        }
    }

    @Test("the Moodle token harvest stops at the guard")
    func moodleTokenHarvest() async {
        let blocked = await SchoolNetworkGuard.capturing {
            await #expect(throws: (any Error).self) {
                try await MoodleTokenService.shared.obtainToken(studentId: "B11000000", password: "password")
            }
        }

        #expect(blocked.map(\.seam) == ["Moodle token harvest"])
    }

    @Test("a Moodle token renewal with the stored password stops at the guard")
    func moodleTokenRefresh() async {
        await withExclusiveRealDefaults {
            let blocked = await SchoolNetworkGuard.capturing {
                await SecureStore.$sharedForTesting.withValue(MemoryKeychain.signedIn(withMoodleToken: false)) {
                    await #expect(throws: (any Error).self) {
                        try await MoodleTokenService.shared.refreshTokenIfNeeded()
                    }
                }
            }

            #expect(blocked.map(\.seam) == ["Moodle token harvest"])
        }
    }

    @Test("the library sign-in stops at the guard")
    func librarySignIn() async {
        let blocked = await SchoolNetworkGuard.capturing {
            await #expect(throws: (any Error).self) {
                try await LibraryService.login(username: "B11000000", password: "password")
            }
        }

        #expect(blocked.map(\.seam) == ["library sign-in"])
        #expect(blocked.map(\.target) == ["POST api.lib.ntust.edu.tw/v1/passport/login"])
    }

    @Test("the SSO probe and the automatic SSO sign-in stop at the guard")
    func ssoProbeAndAutomaticSignIn() async throws {
        try #require(NTUSTSessionManager.shared.session.configuration.protocolClasses?.first == SchoolNetworkGuard.self)
        let auth = AuthService(keychainHasCredentials: { false }, notificationCenter: NotificationCenter())
        var signedIn = true

        let blocked = await SchoolNetworkGuard.capturing {
            signedIn = await SecureStore.$sharedForTesting.withValue(MemoryKeychain.signedIn()) {
                await auth.ensureAuthenticated()
            }
        }

        #expect(!signedIn)
        #expect(blocked.map(\.seam) == ["SSO probe", "SSO sign-in"])
    }

    #if os(iOS)
    @Test("the School Mail client fails the test and connects to nothing")
    func schoolMailClient() async {
        let account = MailAccountManager(
            prefs: InMemoryMailPreferences(),
            credentials: MailCredentialStore(storage: InMemoryMailSecretStorage()),
            cache: SchoolMailTestDoubles.temporaryCache()
        )

        await withKnownIssue {
            await account.login(studentID: "B11000000", password: "password")
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains(RefusingMailClient.seam) }
        }

        #expect(!account.isLoggedIn)
        #expect(account.loginError != nil)
    }
    #endif
}
