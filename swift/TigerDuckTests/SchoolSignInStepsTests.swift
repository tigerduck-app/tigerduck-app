import Defaults
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct SchoolSignInStepsTests {
    @MainActor
    private final class Calls {
        var harvests = 0
        var onSchoolAnswer: () -> Void = {}
    }

    private static let student = "B11000000"
    private static let anotherStudent = "B10900001"

    private static func auth(recording calls: Calls) -> AuthService {
        let auth = AuthService(
            keychainHasCredentials: { false },
            notificationCenter: NotificationCenter(),
            moodleTokens: MoodleTokenService(
                storedCredentials: { nil },
                tokens: .init(load: { nil }, save: { _ in }, drop: {}),
                harvest: { _, _ in
                    await MainActor.run { calls.harvests += 1 }
                    return .init(signature: "", wstoken: "harvested", privatetoken: nil)
                }
            ),
            schoolSignIn: { _, _ in
                await MainActor.run { calls.onSchoolAnswer() }
                return true
            },
            endSchoolSession: { _ in }
        )
        #if os(iOS)
        auth.accountNotifications = DeliveredNotificationsStub()
        #endif
        return auth
    }

    private static func withKeychain(
        libraryAccount: String?,
        _ body: (MemoryKeychain) async throws -> Void
    ) async throws {
        try await withExclusiveRealDefaults {
            let saved = Defaults[.ntustCredentialsPresent]
            defer { Defaults[.ntustCredentialsPresent] = saved }
            let keychain = MemoryKeychain.locked()
            if let libraryAccount {
                try keychain.setObject(Data(libraryAccount.utf8), forKey: AppConstants.KeychainKeys.libraryUsername)
                try keychain.setObject(Data("library".utf8), forKey: AppConstants.KeychainKeys.libraryPassword)
            }
            try await SecureStore.$sharedForTesting.withValue(keychain) { try await body(keychain) }
        }
    }

    private static let libraryAccounts: [String?] = [nil, student, anotherStudent]

    @Test("a school sign-in leaves the library account as it found it", arguments: libraryAccounts)
    func aSchoolSignInLeavesTheLibraryAlone(libraryAccount: String?) async throws {
        let calls = Calls()
        try await Self.withKeychain(libraryAccount: libraryAccount) { keychain in
            let auth = Self.auth(recording: calls)

            #expect(await auth.login(studentId: Self.student, password: "school"))

            #expect(LibraryService.storedUsername == libraryAccount)
            #expect((try? keychain.object(forKey: AppConstants.KeychainKeys.libraryPassword))
                == libraryAccount.map { _ in Data("library".utf8) })
            #expect(LibraryService.storedToken == nil)
        }
        #expect(calls.harvests == 1)
    }

    #if os(iOS)
    /// The sign-out's service steps alone: the call that took the mail with it was in
    /// `AppState.logoutNTUST`, which tests cannot build.
    @Test func aSchoolSignOutLeavesSchoolMailSignedIn() async throws {
        let calls = Calls()
        let mail = MailAccountManagerTests.harness()
        await mail.manager.login(studentID: Self.student, password: "mail")
        try #require(mail.manager.isLoggedIn)
        try await Self.withKeychain(libraryAccount: nil) { _ in
            let auth = Self.auth(recording: calls)
            #expect(await auth.login(studentId: Self.student, password: "school"))

            auth.logout()
            LibraryService.schoolAccountDidSignOut()

            #expect(mail.manager.isLoggedIn)
            #expect(mail.manager.studentID == Self.student)
            #expect(mail.hooks.signedOut == 0)
            #expect(mail.secrets.load(forKey: MailCredentialStore.passwordKey) == "mail")
        }
    }
    #endif

    @Test func aSignOutAsTheSchoolStepEndsKeepsNothing() async throws {
        let calls = Calls()
        try await Self.withKeychain(libraryAccount: nil) { keychain in
            let auth = Self.auth(recording: calls)
            calls.onSchoolAnswer = { auth.logout() }

            let signedIn = await auth.login(studentId: Self.student, password: "school")

            #expect(!signedIn)
            #expect((try? keychain.object(forKey: AppConstants.KeychainKeys.studentId)) == nil)
            #expect((try? keychain.object(forKey: AppConstants.KeychainKeys.password)) == nil)
            #expect(!auth.isLoggingIn)
        }
        #expect(calls.harvests == 0)
    }

    @Test func aSignInWithNoSignOutSavesTheAccount() async throws {
        let calls = Calls()
        try await Self.withKeychain(libraryAccount: nil) { keychain in
            let auth = Self.auth(recording: calls)

            let signedIn = await auth.login(studentId: Self.student, password: "school")

            #expect(signedIn)
            #expect((try? keychain.object(forKey: AppConstants.KeychainKeys.studentId)) == Data(Self.student.utf8))
        }
        #expect(calls.harvests == 1)
    }

    @MainActor
    private final class SheetSignIn {
        var task: Task<Bool, Never>?
        var signOutCallsEnded = false
        var schoolStepStarted = false
    }

    private static func storedAccountIsUntouched(_ keychain: MemoryKeychain) -> Bool {
        (try? keychain.object(forKey: AppConstants.KeychainKeys.studentId)) == Data(Self.anotherStudent.utf8)
    }

    @Test func aSignInCancelledWhileItWaitsSignsNothingOutOrIn() async throws {
        let calls = Calls()
        try await Self.withKeychain(libraryAccount: nil) { keychain in
            try keychain.setObject(Data(Self.anotherStudent.utf8), forKey: AppConstants.KeychainKeys.studentId)
            try keychain.setObject(Data("other".utf8), forKey: AppConstants.KeychainKeys.password)
            let auth = Self.auth(recording: calls)
            let sheet = SheetSignIn()
            auth.signOutStoredAccount = { Issue.record("the stored account was signed out") }
            calls.onSchoolAnswer = { Issue.record("the school sign-in went out") }
            _ = auth.startSignOutCalls {
                while !sheet.signOutCallsEnded { try? await Task.sleep(for: .milliseconds(5)) }
            }

            sheet.task = Task { await auth.login(studentId: Self.student, password: "school") }
            sheet.task?.cancel()
            sheet.signOutCallsEnded = true

            #expect(await sheet.task?.value == false)
            #expect(Self.storedAccountIsUntouched(keychain))
            #expect(auth.loginError == nil)
            #expect(!auth.isLoggingIn)
        }
        #expect(calls.harvests == 0)
    }

    @Test func aSignInCancelledWhileTheStoredAccountSignsOutGoesNoFurther() async throws {
        let calls = Calls()
        try await Self.withKeychain(libraryAccount: nil) { keychain in
            try keychain.setObject(Data(Self.anotherStudent.utf8), forKey: AppConstants.KeychainKeys.studentId)
            try keychain.setObject(Data("other".utf8), forKey: AppConstants.KeychainKeys.password)
            let auth = Self.auth(recording: calls)
            let sheet = SheetSignIn()
            auth.signOutStoredAccount = {
                sheet.task?.cancel()
                try? keychain.removeObject(forKey: AppConstants.KeychainKeys.studentId)
                try? keychain.removeObject(forKey: AppConstants.KeychainKeys.password)
            }
            calls.onSchoolAnswer = { Issue.record("the school sign-in went out") }

            sheet.task = Task { await auth.login(studentId: Self.student, password: "school") }

            #expect(await sheet.task?.value == false)
            #expect((try? keychain.object(forKey: AppConstants.KeychainKeys.studentId)) == nil)
            #expect(auth.loginError == nil)
        }
        #expect(calls.harvests == 0)
    }

    @Test func aSignInCancelledAsTheSchoolAnswersSavesNothing() async throws {
        let calls = Calls()
        try await Self.withKeychain(libraryAccount: nil) { keychain in
            let auth = Self.auth(recording: calls)
            let sheet = SheetSignIn()
            calls.onSchoolAnswer = { sheet.task?.cancel() }

            sheet.task = Task { await auth.login(studentId: Self.student, password: "school") }

            #expect(await sheet.task?.value == false)
            #expect((try? keychain.object(forKey: AppConstants.KeychainKeys.studentId)) == nil)
            #expect(!auth.isLoggingIn)
        }
        #expect(calls.harvests == 0)
    }

    @Test func aSignOutFromAnotherWindowDuringTheSchoolStepShowsNoError() async throws {
        for failure in [URLError(.cancelled) as any Error, CancellationError()] {
            try await Self.withKeychain(libraryAccount: nil) { _ in
                let calls = Calls()
                let auth = AuthService(
                    keychainHasCredentials: { false },
                    notificationCenter: NotificationCenter(),
                    schoolSignIn: { _, _ in
                        await MainActor.run { calls.onSchoolAnswer() }
                        throw failure
                    },
                    endSchoolSession: { _ in }
                )
                calls.onSchoolAnswer = { auth.logout() }

                #expect(await auth.login(studentId: Self.student, password: "school") == false)
                #expect(auth.loginError == nil)
                #expect(!auth.isLoggingIn)
            }
        }
    }

    /// The school's requests end with the task, as `URLSession`'s do.
    @Test func aSignInCancelledDuringTheSchoolStepShowsNoError() async throws {
        try await Self.withKeychain(libraryAccount: nil) { keychain in
            let sheet = SheetSignIn()
            let auth = AuthService(
                keychainHasCredentials: { false },
                notificationCenter: NotificationCenter(),
                schoolSignIn: { _, _ in
                    await MainActor.run { sheet.schoolStepStarted = true }
                    try await Task.sleep(for: .seconds(60))
                    return true
                },
                endSchoolSession: { _ in }
            )

            sheet.task = Task { await auth.login(studentId: Self.student, password: "school") }
            try await waitUntil { sheet.schoolStepStarted }
            sheet.task?.cancel()

            #expect(await sheet.task?.value == false)
            #expect(auth.loginError == nil)
            #expect(!auth.isLoggingIn)
            #expect((try? keychain.object(forKey: AppConstants.KeychainKeys.studentId)) == nil)
        }
    }
}
