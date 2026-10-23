import Foundation
import Testing
@testable import TigerDuck

@Suite("Signing in over a stored account")
@MainActor
struct StoredAccountSignInTests {
    @MainActor
    private final class Calls {
        var signOuts = 0
        var schoolSignIns: [(studentId: String, signOutsBefore: Int)] = []
    }

    @MainActor
    private final class Held {
        var isDone = false
    }

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
            await Task.yield()
            try? keychain.removeObject(forKey: AppConstants.KeychainKeys.studentId)
            try? keychain.removeObject(forKey: AppConstants.KeychainKeys.password)
            calls.signOuts += 1
        }
        #if os(iOS)
        auth.accountNotifications = DeliveredNotificationsStub()
        #endif
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

    @Test("the sign-in sheets ask first for the sign-ins that sign the stored account out, and only those")
    func sheetsAskBeforeTheSignOutsOfLogin() {
        #expect(AuthService.replacesStoredAccount(stored: "B11000000", signingInAs: "B11099999"))
        #expect(!AuthService.replacesStoredAccount(stored: "B11000000", signingInAs: " b11000000 "))
        #expect(!AuthService.replacesStoredAccount(stored: nil, signingInAs: "B11099999"))
    }

    @Test("a sign-in right after a sign-out waits for the calls the sign-out still has out")
    func signInWaitsForTheSignOutsCalls() async throws {
        let calls = Calls()
        let keychain = MemoryKeychain.locked()
        let auth = Self.auth(recording: calls, keychain: keychain)
        let unregister = Held()
        _ = auth.startSignOutCalls {
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

    @Test("a sign-in waits for the calls of every sign-out still out, not only the last one's")
    func signInWaitsForEverySignOutsCalls() async throws {
        let calls = Calls()
        let keychain = MemoryKeychain.locked()
        let auth = Self.auth(recording: calls, keychain: keychain)
        let firstUnregister = Held()
        _ = auth.startSignOutCalls {
            while !firstUnregister.isDone { try? await Task.sleep(for: .milliseconds(5)) }
        }
        _ = auth.startSignOutCalls {}

        let signingIn = Task { @MainActor in
            await SecureStore.$sharedForTesting.withValue(keychain) {
                _ = await auth.login(studentId: "B11000000", password: "password")
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls.schoolSignIns.isEmpty)

        firstUnregister.isDone = true
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
