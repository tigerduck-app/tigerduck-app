// `AuthService.login` and the sign-ins after the school's, against stand-ins that keep every request
// in the process. Saving an account writes real `Defaults` keys, so each test holds the gate in
// `docs/decisions/0020-real-defaults-gate.md` and puts them back.
import Defaults
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct SchoolSignInStepsTests {
    @MainActor
    private final class Calls {
        /// The student ID of each library sign-in request.
        var librarySignIns: [String] = []
        var harvests = 0
        /// Runs inside the stand-in school sign-in, after the school's answer came back.
        var onSchoolAnswer: () -> Void = {}
    }

    private static let student = "B11000000"
    private static let anotherStudent = "B10900001"

    private static func auth(recording calls: Calls) -> AuthService {
        AuthService(
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
    }

    /// Runs `body` with a keychain of its own, holding the library account of `libraryAccount`
    /// with no live token, and `rejected` as the library's refusal of its stored password.
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

    // MARK: - The library step (https://github.com/tigerduck-app/tigerduck-app/issues/542)

    /// Its token ran out, but its stored credentials sign in again behind the code, so Settings
    /// shows it signed in and a school sign-out would keep it.
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

    /// The school has just checked this password, so this student's library account takes it in
    /// place of the stored one, which a changed school password leaves behind.
    @Test func theSameStudentsLibraryAccountSignsInWithTheSchoolPassword() async throws {
        let calls = Calls()
        try await Self.withKeychain(libraryAccount: Self.student) { _ in
            let auth = Self.auth(recording: calls)
            await auth.signInToServices(studentId: Self.student, password: "school", generation: auth.loginGeneration)

            #expect(calls.librarySignIns == [Self.student])
            #expect(LibraryService.storedPasswordIfAvailable() == "school")
        }
    }
}
