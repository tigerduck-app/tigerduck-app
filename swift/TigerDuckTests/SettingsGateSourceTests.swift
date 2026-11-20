#if os(iOS)
import Defaults
import Foundation
import Observation
import Testing
@testable import TigerDuck

@MainActor
struct SettingsGateSourceTests {
    // Observation calls `onChange` on the thread that makes the change, the main thread here.
    private final class Changes: @unchecked Sendable {
        var count = 0
    }

    private static let gates: [SettingsGate] = [.tigerSync, .schoolSignIn, .mailSignIn, .librarySignIn]

    @Test("each gate opens and closes on its own account, and each change reaches an observer")
    func eachGateFollowsItsOwnAccount() async throws {
        try await LibrarySignInTests.withStoredAccount { keychain in
            var schoolKeychainHasCredentials = false
            let school = AuthService(
                keychainHasCredentials: { schoolKeychainHasCredentials }, notificationCenter: NotificationCenter()
            )
            let saved = Defaults[.ntustCredentialsPresent]
            defer { Defaults[.ntustCredentialsPresent, for: testSignIn] = saved }
            school.markCredentialsChanged()
            let library = LibraryAccountStatus()
            let mail = MailAccountManagerTests.harness().manager
            var isCloudSyncOn = false

            func state() -> SettingsState {
                SettingsState(school: school, library: library, mail: mail, isCloudSyncOn: isCloudSyncOn)
            }
            func open() -> [SettingsGate] {
                Self.gates.filter { $0.isOpen(in: state()) }
            }
            func observed(_ change: () async throws -> Void) async throws {
                let changes = Changes()
                withObservationTracking { _ = state() } onChange: { changes.count += 1 }
                try await change()
                try await waitUntil { changes.count > 0 }
            }

            #expect(open() == [.librarySignIn])
            try await observed { library.logout() }
            #expect(open() == [])

            try await observed {
                schoolKeychainHasCredentials = true
                school.markCredentialsChanged()
            }
            #expect(open() == [.schoolSignIn])
            try await observed {
                schoolKeychainHasCredentials = false
                school.markCredentialsChanged()
            }
            #expect(open() == [])

            try await observed { await mail.login(studentID: "B10000000", password: "pw") }
            #expect(open() == [.mailSignIn])
            try await observed { mail.logout() }
            #expect(open() == [])

            try await observed {
                try keychain.setObject(Data("B1LIB".utf8), forKey: AppConstants.KeychainKeys.libraryUsername)
                try keychain.setObject(Data("password".utf8), forKey: AppConstants.KeychainKeys.libraryPassword)
                NotificationCenter.default.post(name: LibraryService.signInDidChange, object: nil)
            }
            #expect(open() == [.librarySignIn])
            library.logout()

            isCloudSyncOn = true
            #expect(open() == [.tigerSync])
        }
    }
}
#endif
