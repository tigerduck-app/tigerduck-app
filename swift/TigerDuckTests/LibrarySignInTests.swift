#if os(iOS)
import Defaults
import Foundation
import Testing
@testable import TigerDuck

/// Signing in to the library again with the stored credentials once the day-long token runs out,
/// as the app does at launch, on each return and when the Library page opens. The sign-in request
/// is a stand-in, so nothing leaves the process.
///
/// A refusal is kept in a real `Defaults` key, so these tests hold the gate in
/// `docs/decisions/0020-real-defaults-gate.md` and put the key back.
@MainActor
struct LibrarySignInTests {
    @MainActor
    private final class Calls {
        var count = 0
        /// Holds a stand-in request until the test opens it, so the test can act while it is out.
        var isOpen = false
        /// What a caller's own account check answers.
        var callerIsCurrent = true
    }

    /// The broadcaster's epoch, which every message to the Watch moves.
    private static var watchEpoch: Int {
        UserDefaults(suiteName: "group.org.ntust.app.TigerDuck")?.integer(forKey: "watchLibraryCredEpoch") ?? 0
    }

    private static func answer() -> LibraryLoginData {
        let expiry = Date().addingTimeInterval(86_400).timeIntervalSince1970 * 1000
        return LibraryLoginData(username: "", token: "token", expirationTimeStamp: Int64(expiry))
    }

    /// Runs `body` with a library account of its own in the keychain and no refusal on record.
    private static func withStoredAccount(_ body: (MemoryKeychain) async throws -> Void) async throws {
        try await withExclusiveRealDefaults {
            let saved = LibraryService.storedPasswordRejected
            LibraryService.storedPasswordRejected = false
            defer { LibraryService.storedPasswordRejected = saved }
            let keychain = MemoryKeychain.locked()
            let username = "B1LIB" + UUID().uuidString.prefix(8)
            try keychain.setObject(Data(username.utf8), forKey: AppConstants.KeychainKeys.libraryUsername)
            try keychain.setObject(Data("password".utf8), forKey: AppConstants.KeychainKeys.libraryPassword)
            try await SecureStore.$sharedForTesting.withValue(keychain) { try await body(keychain) }
        }
    }

    private static func refusesAnswer(withStatus status: Int) -> Bool {
        let url = URL(string: "https://api.lib.ntust.edu.tw/v1/passport/login")!
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        do {
            _ = try LibraryService.loginAnswer(response, data: Data())
            return false
        } catch LibraryServiceError.loginFailed {
            return true
        } catch {
            return false
        }
    }

    /// A sign-in the app makes by itself, for the Library page's code or the Watch's, reaches the
    /// screens that show the library account, as one from the sign-in form does (#438).
    @Test func aSignInWithTheStoredCredentialsIsAnnounced() async throws {
        let calls = Calls()
        try await Self.withStoredAccount { _ in
            let observer = NotificationCenter.default.addObserver(
                forName: LibraryService.signInDidChange, object: nil, queue: nil
            ) { _ in MainActor.assumeIsolated { calls.count += 1 } }
            defer { NotificationCenter.default.removeObserver(observer) }
            _ = try await LibraryService.ensureToken { _, _ in Self.answer() }
            #expect(calls.count > 0)
        }
    }

    @Test func credentialsTheLibraryRefusedAreNotSentAgain() async throws {
        let calls = Calls()
        let announcements = Calls()
        try await Self.withStoredAccount { _ in
            #expect(LibraryService.canSignInWithStoredCredentials)
            let epoch = Self.watchEpoch
            // The refusal signs the account out, which Settings and the flip have to hear.
            let observer = NotificationCenter.default.addObserver(
                forName: LibraryService.signInDidChange, object: nil, queue: nil
            ) { _ in MainActor.assumeIsolated { announcements.count += 1 } }
            defer { NotificationCenter.default.removeObserver(observer) }
            _ = try? await LibraryService.ensureToken { _, _ in
                calls.count += 1
                throw LibraryServiceError.loginFailed("wrong password")
            }
            #expect(announcements.count == 1)
            // Kept in the defaults, so the next launch does not send it either.
            #expect(Defaults[.libraryStoredPasswordRejected])
            #expect(!LibraryService.canSignInWithStoredCredentials)
            // The Watch is told to drop its copy, and is not handed the password again.
            #expect(Self.watchEpoch == epoch + 1)
            #expect(LibraryService.storedPasswordIfAvailable() == nil)

            _ = try? await LibraryService.ensureToken { _, _ in
                calls.count += 1
                return Self.answer()
            }
            #expect(calls.count == 1)
        }
    }

    /// Credentials saved by a sign-in that worked end the refusal of the ones before.
    @Test func savedCredentialsEndTheRefusal() async throws {
        try await Self.withStoredAccount { _ in
            LibraryService.storedPasswordRejected = true
            LibraryService.saveCredentials(username: try #require(LibraryService.storedUsername), password: "new")
            #expect(LibraryService.canSignInWithStoredCredentials)
        }
    }

    @Test func aFailedRequestTriesAgainNextTime() async throws {
        let calls = Calls()
        try await Self.withStoredAccount { _ in
            _ = try? await LibraryService.ensureToken { _, _ in
                calls.count += 1
                throw LibraryServiceError.networkError(URLError(.notConnectedToInternet))
            }
            #expect(LibraryService.canSignInWithStoredCredentials)

            let token = try? await LibraryService.ensureToken { _, _ in
                calls.count += 1
                return Self.answer()
            }
            #expect(token == "token")
            #expect(calls.count == 2)
        }
    }

    /// Launch and the Library page can both ask while the first sign-in is still on the wire.
    @Test func callersThatArriveTogetherShareOneSignIn() async throws {
        let calls = Calls()
        let signIn: @MainActor (String, String) async throws -> LibraryLoginData = { _, _ in
            calls.count += 1
            try await waitUntil { calls.isOpen }
            return Self.answer()
        }
        try await Self.withStoredAccount { _ in
            let first = Task { try await LibraryService.ensureToken(signIn: signIn) }
            let second = Task { try await LibraryService.ensureToken(signIn: signIn) }
            try await waitUntil { calls.count == 1 }
            calls.isOpen = true

            #expect(try await first.value == "token")
            #expect(try await second.value == "token")
            #expect(calls.count == 1)
        }
    }

    /// The answer to a sign-in still out when the user signed out puts nothing back.
    @Test func aSignOutDuringTheSignInKeepsNothing() async throws {
        let calls = Calls()
        try await Self.withStoredAccount { _ in
            let signingIn = Task {
                try await LibraryService.ensureToken { _, _ in
                    calls.count += 1
                    try await waitUntil { calls.isOpen }
                    return Self.answer()
                }
            }
            try await waitUntil { calls.count == 1 }
            LibraryService.clearCredentials()
            calls.isOpen = true

            await #expect(throws: LibraryServiceError.self) { try await signingIn.value }
            #expect(LibraryService.storedToken == nil)
            #expect(LibraryService.storedUsername == nil)
        }
    }

    /// A refusal of the password the user has since replaced says nothing about the new one.
    @Test func aRefusalOfAReplacedPasswordIsNotKept() async throws {
        let calls = Calls()
        try await Self.withStoredAccount { keychain in
            let signingIn = Task {
                try await LibraryService.ensureToken { _, _ in
                    calls.count += 1
                    try await waitUntil { calls.isOpen }
                    throw LibraryServiceError.loginFailed("wrong password")
                }
            }
            try await waitUntil { calls.count == 1 }
            try keychain.setObject(Data("new".utf8), forKey: AppConstants.KeychainKeys.libraryPassword)
            calls.isOpen = true

            _ = try? await signingIn.value
            #expect(LibraryService.canSignInWithStoredCredentials)
        }
    }

    /// Control Center and the app switcher each count as a return to the app.
    @Test func aReturnSoonAfterAFailureSendsNothing() async throws {
        let calls = Calls()
        try await Self.withStoredAccount { _ in
            _ = try? await LibraryService.ensureToken { _, _ in
                throw LibraryServiceError.networkError(URLError(.timedOut))
            }
            let signedIn = await LibraryService.signInIfCredentialed { _, _ in
                calls.count += 1
                return Self.answer()
            }
            #expect(!signedIn)
            #expect(calls.count == 0)
            // A sign-in that works ends the pause, so none is left for a later test.
            _ = try? await LibraryService.ensureToken { _, _ in Self.answer() }
        }
    }

    /// A typed sign-in still out when the user signed out of the library saves nothing.
    @Test func aSignOutDuringATypedSignInKeepsNothing() async throws {
        let calls = Calls()
        try await Self.withStoredAccount { _ in
            let signingIn = Task {
                try await LibraryService.login(username: "B1LIBTYPED", password: "typed", request: { _, _ in
                    calls.count += 1
                    try await waitUntil { calls.isOpen }
                    return Self.answer()
                })
            }
            try await waitUntil { calls.count == 1 }
            LibraryService.clearCredentials()
            calls.isOpen = true

            await #expect(throws: LibraryServiceError.self) { try await signingIn.value }
            #expect(LibraryService.storedUsername == nil)
            #expect(LibraryService.storedToken == nil)
        }
    }

    /// The school sign-in's library step: no library account of that ID is stored yet, so a school
    /// sign-out meanwhile moves no library generation, and only the caller can tell.
    @Test func aSignInItsCallerNoLongerWantsKeepsNothing() async throws {
        let calls = Calls()
        try await Self.withStoredAccount { _ in
            let signingIn = Task {
                try await LibraryService.login(
                    username: "B1LIBSCHOOL",
                    password: "school",
                    stillCurrent: { calls.callerIsCurrent },
                    request: { _, _ in
                        calls.count += 1
                        try await waitUntil { calls.isOpen }
                        return Self.answer()
                    }
                )
            }
            try await waitUntil { calls.count == 1 }
            calls.callerIsCurrent = false
            calls.isOpen = true

            await #expect(throws: LibraryServiceError.self) { try await signingIn.value }
            #expect(LibraryService.storedUsername != "B1LIBSCHOOL")
            #expect(LibraryService.storedToken == nil)
        }
    }

    @Test func aSchoolSignOutTakesTheLibraryAccountOfTheSameID() async throws {
        try await Self.withStoredAccount { _ in
            let username = try #require(LibraryService.storedUsername)
            #expect(!LibraryService.clearCredentials(ifSchoolAccount: "B19999999"))
            #expect(LibraryService.storedUsername == username)

            #expect(LibraryService.clearCredentials(ifSchoolAccount: username.lowercased()))
            #expect(LibraryService.storedUsername == nil)
        }
    }

    /// The token lasts a day, and the Library page signs in again behind its code, so an account
    /// whose token ran out still counts as signed in for Settings and the flip
    /// (https://github.com/tigerduck-app/tigerduck-app/issues/528).
    @Test func storedCredentialsCountAsSignedInOnceTheTokenRunsOut() async throws {
        try await Self.withStoredAccount { _ in
            #expect(!LibraryService.isTokenValid)
            #expect(LibraryService.hasAccount)
            LibraryService.storedPasswordRejected = true
            #expect(!LibraryService.hasAccount)
        }
        try await withExclusiveRealDefaults {
            try await SecureStore.$sharedForTesting.withValue(MemoryKeychain.locked()) {
                #expect(!LibraryService.hasAccount)
            }
        }
    }

    /// A code request that fails short of a refusal, as on a weak signal at the gate, keeps the
    /// page signed in to try again: the stored credentials can still sign in.
    @Test func aFailedCodeRequestKeepsAStoredAccountSignedIn() async throws {
        try await Self.withStoredAccount { _ in
            LibraryQRCache.shared.clear()
            let model = LibraryViewModel()
            defer { model.stopTimers() }
            model.fetchCode = { throw URLError(.timedOut) }
            model.load()
            model.onAppear()
            try await waitUntil { model.errorMessage != nil }
            #expect(model.isLoggedIn)
        }
    }

    @Test func aRefusedCodeRequestSignsThePageOut() async throws {
        try await Self.withStoredAccount { _ in
            LibraryQRCache.shared.clear()
            let model = LibraryViewModel()
            defer { model.stopTimers() }
            model.fetchCode = {
                LibraryService.storedPasswordRejected = true
                throw LibraryServiceError.loginFailed("wrong password")
            }
            model.load()
            model.onAppear()
            try await waitUntil { !model.isLoggedIn }
        }
    }

    /// A retry that works after a failed code request fetches a fresh code every cycle after it,
    /// rather than leaving the one it fetched to run out on screen.
    @Test func aRetryAfterAFailureKeepsRefreshingTheCode() async throws {
        try await Self.withStoredAccount { _ in
            LibraryQRCache.shared.clear()
            let calls = Calls()
            let model = LibraryViewModel()
            defer { model.stopTimers() }
            model.backoffSchedule = [0.05]
            model.refreshInterval = 0.1
            model.fetchCode = {
                calls.count += 1
                if calls.count == 1 { throw URLError(.timedOut) }
                return "code-\(calls.count)"
            }
            model.load()
            model.onAppear()
            try await waitUntil { calls.count >= 4 }
        }
    }

    @Test func anAccountChangeKeepsAStoredAccountSignedIn() async throws {
        try await Self.withStoredAccount { _ in
            let model = LibraryViewModel()
            NotificationCenter.default.post(name: LibraryService.accountDidChange, object: nil)
            #expect(model.isLoggedIn)
        }
    }

    /// A refusal found by another caller, such as the sign-in at launch or for the Watch, signs out
    /// a page waiting to retry a failed code request at once, not at its retry
    /// (https://github.com/tigerduck-app/tigerduck-app/issues/556).
    @Test func aRefusalElsewhereSignsOutAPageBackingOff() async throws {
        try await Self.withStoredAccount { _ in
            LibraryQRCache.shared.clear()
            let model = LibraryViewModel()
            defer { model.stopTimers() }
            model.backoffSchedule = [300]
            model.fetchCode = { throw URLError(.timedOut) }
            model.load()
            model.onAppear()
            try await waitUntil { model.errorMessage != nil }
            #expect(model.isLoggedIn)

            _ = try? await LibraryService.ensureToken { _, _ in throw LibraryServiceError.loginFailed("wrong password") }

            #expect(!model.isLoggedIn)
            #expect(model.errorMessage == nil)
        }
    }

    /// A sign-in that worked elsewhere leaves a signed-in page as it is.
    @Test func aSignInElsewhereKeepsThePageSignedIn() async throws {
        try await Self.withStoredAccount { _ in
            LibraryQRCache.shared.clear()
            let model = LibraryViewModel()
            defer { model.stopTimers() }
            model.backoffSchedule = [300]
            model.fetchCode = { throw URLError(.timedOut) }
            model.load()
            model.onAppear()
            try await waitUntil { model.errorMessage != nil }

            _ = try await LibraryService.ensureToken { _, _ in Self.answer() }

            #expect(model.isLoggedIn)
        }
    }

    @Test func thePauseRunsFromTheFailure() {
        let failure = Date(timeIntervalSince1970: 1_000_000)
        #expect(LibraryService.signInIsDue(lastFailure: nil, now: failure))
        #expect(!LibraryService.signInIsDue(lastFailure: failure, now: failure.addingTimeInterval(60)))
        #expect(LibraryService.signInIsDue(lastFailure: failure, now: failure.addingTimeInterval(LibraryService.signInPause)))
        // A clock set back does not stretch it.
        #expect(LibraryService.signInIsDue(lastFailure: failure, now: failure.addingTimeInterval(-60)))
    }

    /// What a wrong password gets is unchecked, so any 4xx counts as a refusal; a 5xx does not.
    @Test func aClientErrorAnswerIsARefusal() {
        #expect(Self.refusesAnswer(withStatus: 401))
        #expect(Self.refusesAnswer(withStatus: 429))
        #expect(!Self.refusesAnswer(withStatus: 503))
    }
}
#endif
