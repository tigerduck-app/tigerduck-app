import Defaults
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct SchoolSignInStepsTests {
    @MainActor
    private final class Calls {
        var librarySignIns: [String] = []
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
            librarySignIn: { username, _ in
                calls.librarySignIns.append(username)
                let expiry = Date().addingTimeInterval(86_400).timeIntervalSince1970 * 1000
                return LibraryLoginData(username: username, token: "library-token", expirationTimeStamp: Int64(expiry))
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
        rejected: Bool = false,
        _ body: (MemoryKeychain) async throws -> Void
    ) async throws {
        try await withExclusiveRealDefaults {
            let saved = (LibraryService.storedPasswordRejected, Defaults[.ntustCredentialsPresent])
            LibraryService.storedPasswordRejected = rejected
            defer { (LibraryService.storedPasswordRejected, Defaults[.ntustCredentialsPresent]) = saved }
            let keychain = MemoryKeychain.locked()
            if let libraryAccount {
                try keychain.setObject(Data(libraryAccount.utf8), forKey: AppConstants.KeychainKeys.libraryUsername)
                try keychain.setObject(Data("library".utf8), forKey: AppConstants.KeychainKeys.libraryPassword)
            }
            try await SecureStore.$sharedForTesting.withValue(keychain) { try await body(keychain) }
        }
    }

    @Test func anotherStudentsLibraryAccountStaysOnceItsTokenRunsOut() async throws {
        let calls = Calls()
        try await Self.withKeychain(libraryAccount: Self.anotherStudent) { _ in
            let auth = Self.auth(recording: calls)
            await auth.signInToServices(studentId: Self.student, password: "school", generation: auth.loginGeneration)

            #expect(calls.librarySignIns.isEmpty)
            #expect(LibraryService.storedUsername == Self.anotherStudent)
        }
        #expect(calls.harvests == 1)
    }

    @Test func aLibraryAccountTheLibraryRefusedTakesTheSchoolAccount() async throws {
        let calls = Calls()
        try await Self.withKeychain(libraryAccount: Self.anotherStudent, rejected: true) { _ in
            let auth = Self.auth(recording: calls)
            await auth.signInToServices(studentId: Self.student, password: "school", generation: auth.loginGeneration)

            #expect(calls.librarySignIns == [Self.student])
            #expect(LibraryService.storedUsername == Self.student)
        }
    }

    @Test func withNoLibraryAccountTheSchoolAccountSignsIn() async throws {
        let calls = Calls()
        try await Self.withKeychain(libraryAccount: nil) { _ in
            let auth = Self.auth(recording: calls)
            await auth.signInToServices(studentId: Self.student, password: "school", generation: auth.loginGeneration)

            #expect(calls.librarySignIns == [Self.student])
            #expect(LibraryService.storedUsername == Self.student)
        }
    }

    @Test func theSameStudentsLibraryAccountSignsInWithTheSchoolPassword() async throws {
        let calls = Calls()
        try await Self.withKeychain(libraryAccount: Self.student) { _ in
            let auth = Self.auth(recording: calls)
            await auth.signInToServices(studentId: Self.student, password: "school", generation: auth.loginGeneration)

            #expect(calls.librarySignIns == [Self.student])
            #expect(LibraryService.storedPasswordIfAvailable() == "school")
        }
    }

    @Test func aSignOutAsTheSchoolStepEndsKeepsNothing() async throws {
        let calls = Calls()
        try await Self.withKeychain(libraryAccount: nil) { keychain in
            let auth = Self.auth(recording: calls)
            calls.onSchoolAnswer = { auth.logout() }

            let signedIn = await auth.login(studentId: Self.student, password: "school")

            #expect(!signedIn)
            #expect((try? keychain.object(forKey: AppConstants.KeychainKeys.studentId)) == nil)
            #expect((try? keychain.object(forKey: AppConstants.KeychainKeys.password)) == nil)
            #expect(calls.librarySignIns.isEmpty)
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
            #expect(calls.librarySignIns == [Self.student])
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
            #expect(calls.librarySignIns.isEmpty)
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
            #expect(calls.librarySignIns.isEmpty)
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
            #expect(calls.librarySignIns.isEmpty)
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
