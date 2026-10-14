// `AuthService.login` while an account is stored, as from the prompt a failed silent sign-in shows
// (https://github.com/tigerduck-app/tigerduck-app/issues/398). The school sign-in is a stand-in that
// fails, so no request leaves the process and nothing after it runs.
import Foundation
import Testing
@testable import TigerDuck

@Suite("Signing in over a stored account")
@MainActor
struct StoredAccountSignInTests {
    @MainActor
    private final class Calls {
        var signOuts = 0
        /// Each school sign-in's student ID, and how many sign-outs had finished when it began.
        var schoolSignIns: [(studentId: String, signOutsBefore: Int)] = []
    }

    @MainActor
    private final class Held {
        var isDone = false
    }

    /// Its sign-out drops the stored account from `keychain`, as `AppState.logoutNTUST()` does.
    private static func auth(recording calls: Calls, keychain: MemoryKeychain) -> AuthService {
        let auth = AuthService(
            keychainHasCredentials: { false },
            notificationCenter: NotificationCenter(),
            schoolSignIn: { studentId, _ in
                calls.schoolSignIns.append((studentId, calls.signOuts))
                return false
            }
        )
        auth.signOutStoredAccount = {
            // The app's sign-out suspends while the backend and push state settle.
            await Task.yield()
            try? keychain.removeObject(forKey: AppConstants.KeychainKeys.studentId)
            try? keychain.removeObject(forKey: AppConstants.KeychainKeys.password)
            calls.signOuts += 1
        }
        return auth
    }

    @Test("another student ID gets the whole sign-out first, and its school sign-in waits for it")
    func anotherStudentIdIsSignedOutFirst() async {
        let calls = Calls()
        let keychain = MemoryKeychain.signedIn()
        let auth = Self.auth(recording: calls, keychain: keychain)

        await SecureStore.$sharedForTesting.withValue(keychain) {
            _ = await auth.login(studentId: "B11099999", password: "another-password")
        }

        #expect(calls.signOuts == 1)
        #expect(calls.schoolSignIns.map(\.studentId) == ["B11099999"])
        #expect(calls.schoolSignIns.map(\.signOutsBefore) == [1])
    }

    @Test("the stored student ID, typed in lower case with spaces, signs in again with nothing signed out")
    func storedStudentIdKeepsTheAccount() async {
        let calls = Calls()
        let keychain = MemoryKeychain.signedIn()
        let auth = Self.auth(recording: calls, keychain: keychain)

        let stored = await SecureStore.$sharedForTesting.withValue(keychain) {
            _ = await auth.login(studentId: " b11000000 ", password: "password")
            return (auth.storedStudentId, auth.storedPassword)
        }

        #expect(calls.signOuts == 0)
        #expect(calls.schoolSignIns.map(\.studentId) == ["B11000000"])
        #expect(stored.0 == "B11000000")
        #expect(stored.1 == "password")
    }

    /// The sign-out's unregister goes out as the departing account after its session ended, and
    /// landing after this sign-in it would revoke the session and push tokens this one registers
    /// (https://github.com/tigerduck-app/tigerduck-app/issues/469).
    @Test("a sign-in right after a sign-out waits for the calls the sign-out still has out")
    func signInWaitsForTheSignOutsCalls() async throws {
        let calls = Calls()
        let keychain = MemoryKeychain.locked()
        let auth = Self.auth(recording: calls, keychain: keychain)
        let unregister = Held()
        auth.signOutCalls = Task { @MainActor in
            while !unregister.isDone { try? await Task.sleep(for: .milliseconds(5)) }
        }

        let signingIn = Task { @MainActor in
            await SecureStore.$sharedForTesting.withValue(keychain) {
                _ = await auth.login(studentId: "B11000000", password: "password")
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls.schoolSignIns.isEmpty)

        unregister.isDone = true
        await signingIn.value
        #expect(calls.schoolSignIns.map(\.studentId) == ["B11000000"])
    }

    @Test("a retry after another student ID's sign-in failed signs nothing out a second time")
    func retryAfterAFailedSignInSignsOutOnce() async {
        let calls = Calls()
        let keychain = MemoryKeychain.signedIn()
        let auth = Self.auth(recording: calls, keychain: keychain)

        await SecureStore.$sharedForTesting.withValue(keychain) {
            _ = await auth.login(studentId: "B11099999", password: "mistyped")
            _ = await auth.login(studentId: "B11099999", password: "another-password")
        }

        #expect(calls.signOuts == 1)
        #expect(calls.schoolSignIns.map(\.signOutsBefore) == [1, 1])
    }
}
