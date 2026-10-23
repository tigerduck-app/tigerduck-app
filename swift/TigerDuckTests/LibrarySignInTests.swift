#if os(iOS)
import Defaults
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct LibrarySignInTests {
    @MainActor
    private final class Calls {
        var count = 0
        var isOpen = false
        var callerIsCurrent = true
    }

    private static var watchEpoch: Int {
        UserDefaults(suiteName: "group.org.ntust.app.TigerDuck")?.integer(forKey: "watchLibraryCredEpoch") ?? 0
    }

    private static func answer() -> LibraryLoginData {
        let expiry = Date().addingTimeInterval(86_400).timeIntervalSince1970 * 1000
        return LibraryLoginData(username: "", token: "token", expirationTimeStamp: Int64(expiry))
    }

    private static func withStoredAccount(
        username: String = "B1LIB" + UUID().uuidString.prefix(8),
        _ body: (MemoryKeychain) async throws -> Void
    ) async throws {
        try await withExclusiveRealDefaults {
            let saved = LibraryService.storedPasswordRefusals
            LibraryService.storedPasswordRefusals = (0, nil)
            defer {
                LibraryService.cancelStoredPasswordRetry()
                LibraryService.storedPasswordRefusals = saved
            }
            let keychain = MemoryKeychain.locked()
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

    @Test func aRefusedPasswordWaitsAndARetryTheLibraryAcceptsEndsTheWait() async throws {
        let calls = Calls()
        let announcements = Calls()
        try await Self.withStoredAccount { _ in
            #expect(LibraryService.canSignInWithStoredCredentials)
            let epoch = Self.watchEpoch
            let observer = NotificationCenter.default.addObserver(
                forName: LibraryService.signInDidChange, object: nil, queue: nil
            ) { _ in MainActor.assumeIsolated { announcements.count += 1 } }
            defer { NotificationCenter.default.removeObserver(observer) }
            _ = try? await LibraryService.ensureToken { _, _ in
                calls.count += 1
                throw LibraryServiceError.loginFailed("wrong password")
            }
            #expect(announcements.count == 1)
            #expect(Defaults[.libraryStoredPasswordRefusals] == 1)
            #expect(!LibraryService.canSignInWithStoredCredentials)
            #expect(Self.watchEpoch == epoch + 1)
            #expect(LibraryService.storedPasswordIfAvailable() == nil)

            _ = try? await LibraryService.ensureToken { _, _ in
                calls.count += 1
                return Self.answer()
            }
            #expect(calls.count == 1)

            let firstWait = SSOLoginService.storedPasswordRetryDelay(afterRefusals: 1)
            LibraryService.storedPasswordRefusals = (1, Date().addingTimeInterval(-firstWait))
            let token = try? await LibraryService.ensureToken { _, _ in
                calls.count += 1
                return Self.answer()
            }
            #expect(token == "token")
            #expect(calls.count == 2)
            #expect(LibraryService.storedPasswordRefusals.count == 0)
            #expect(LibraryService.canSignInWithStoredCredentials)
            #expect(Self.watchEpoch == epoch + 2)
            #expect(LibraryService.storedPasswordIfAvailable() == "password")
        }
    }

    @Test func afterTheQuickRetriesARefusalWaitsSixHours() async throws {
        let calls = Calls()
        try await Self.withStoredAccount { _ in
            let quickTries = SSOLoginService.storedPasswordQuickRetries.count
            let lastQuickWait = SSOLoginService.storedPasswordRetryDelay(afterRefusals: quickTries)
            LibraryService.storedPasswordRefusals = (quickTries, Date().addingTimeInterval(-lastQuickWait))
            _ = try? await LibraryService.ensureToken { _, _ in
                calls.count += 1
                throw LibraryServiceError.loginFailed("wrong password")
            }
            let refused = try #require(LibraryService.storedPasswordRefusals.last)
            #expect(LibraryService.storedPasswordRefusals.count == quickTries + 1)
            #expect(!LibraryService.storedPasswordPostIsDue(now: refused.addingTimeInterval(6 * 60 * 60 - 1)))
            #expect(LibraryService.storedPasswordPostIsDue(now: refused.addingTimeInterval(6 * 60 * 60)))

            _ = try? await LibraryService.ensureToken { _, _ in
                calls.count += 1
                return Self.answer()
            }
            #expect(calls.count == 1)
        }
    }

    @Test func aTypedSignInIsNotHeldBackAndEndsTheWait() async throws {
        let calls = Calls()
        try await Self.withStoredAccount { _ in
            let username = try #require(LibraryService.storedUsername)
            LibraryService.storedPasswordRefusals = (4, Date())
            try await LibraryService.login(username: username, password: "typed", request: { _, _ in
                calls.count += 1
                return Self.answer()
            })
            #expect(calls.count == 1)
            #expect(LibraryService.storedPasswordRefusals.count == 0)
            #expect(LibraryService.storedPasswordPostIsDue(now: Date()))
        }
    }

    @Test func aSignOutWhileARetryWaitsEndsTheWait() async throws {
        try await Self.withStoredAccount { _ in
            LibraryService.storedPasswordRefusals = (1, Date())
            LibraryService.clearCredentials()
            #expect(LibraryService.storedPasswordRefusals.count == 0)
            #expect(LibraryService.storedPasswordRefusals.last == nil)
        }
    }

    @Test func savedCredentialsEndTheRefusal() async throws {
        try await Self.withStoredAccount { _ in
            LibraryService.storedPasswordRefusals = (2, Date())
            LibraryService.saveCredentials(username: try #require(LibraryService.storedUsername), password: "new")
            #expect(LibraryService.canSignInWithStoredCredentials)
            #expect(LibraryService.storedPasswordPostIsDue(now: Date()))
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
            _ = try? await LibraryService.ensureToken { _, _ in Self.answer() }
        }
    }

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

    @Test func aSchoolSignOutKeepsTheLibraryAccount() async throws {
        let announcements = Calls()
        try await Self.withStoredAccount { keychain in
            let username = try #require(LibraryService.storedUsername)
            try keychain.setObject(Data(username.utf8), forKey: AppConstants.KeychainKeys.studentId)
            let observer = NotificationCenter.default.addObserver(
                forName: LibraryService.accountDidChange, object: nil, queue: nil
            ) { _ in MainActor.assumeIsolated { announcements.count += 1 } }
            defer { NotificationCenter.default.removeObserver(observer) }

            LibraryService.schoolAccountDidSignOut()

            #expect(LibraryService.storedUsername == username)
            #expect(LibraryService.canSignInWithStoredCredentials)
            #expect(announcements.count == 0)
        }
    }

    @Test func storedCredentialsCountAsSignedInOnceTheTokenRunsOut() async throws {
        try await Self.withStoredAccount { _ in
            #expect(!LibraryService.isTokenValid)
            #expect(LibraryService.hasAccount)
            LibraryService.storedPasswordRefusals = (1, Date())
            #expect(!LibraryService.hasAccount)
        }
        try await withExclusiveRealDefaults {
            try await SecureStore.$sharedForTesting.withValue(MemoryKeychain.locked()) {
                #expect(!LibraryService.hasAccount)
            }
        }
    }

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
                LibraryService.storedPasswordRefusals = (1, Date())
                throw LibraryServiceError.loginFailed("wrong password")
            }
            model.load()
            model.onAppear()
            try await waitUntil { !model.isLoggedIn }
        }
    }

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

    @Test func theLastSyncIsWhenTheCodeOnScreenWasIssued() async throws {
        try await Self.withStoredAccount { _ in
            LibraryQRCache.shared.clear()
            let model = LibraryViewModel()
            defer { model.stopTimers() }
            model.fetchCode = { "code-1" }
            let before = Date()
            model.load()
            model.onAppear()
            try await waitUntil { model.qrPayload == "code-1" }
            let issued = try #require(model.codeFetchedAt)
            #expect(issued >= before && issued <= Date())

            NotificationCenter.default.post(name: LibraryService.accountDidChange, object: nil)
            #expect(model.codeFetchedAt == nil)
        }
    }

    @Test func anAccountChangeKeepsAStoredAccountSignedIn() async throws {
        try await Self.withStoredAccount { _ in
            let model = LibraryViewModel()
            NotificationCenter.default.post(name: LibraryService.accountDidChange, object: nil)
            #expect(model.isLoggedIn)
        }
    }

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

    private static func refusedOnceAndDue() {
        let firstWait = SSOLoginService.storedPasswordRetryDelay(afterRefusals: 1)
        LibraryService.storedPasswordRefusals = (1, Date().addingTimeInterval(-firstWait))
    }

    @Test func aRetryThatSignsInWhileThePageShowsTheFormShowsTheCode() async throws {
        try await Self.withStoredAccount { _ in
            LibraryQRCache.shared.clear()
            Self.refusedOnceAndDue()
            let model = LibraryViewModel()
            defer { model.stopTimers() }
            model.fetchCode = { "code-1" }
            model.load()
            model.onAppear()
            #expect(!model.isLoggedIn)

            _ = try await LibraryService.ensureToken { _, _ in Self.answer() }

            #expect(model.isLoggedIn)
            try await waitUntil { model.qrPayload == "code-1" }
        }
    }

    @Test func aRetryThatSignsInWhileThePageIsAwayFetchesOnceItShows() async throws {
        let calls = Calls()
        try await Self.withStoredAccount { _ in
            LibraryQRCache.shared.clear()
            Self.refusedOnceAndDue()
            let model = LibraryViewModel()
            defer { model.stopTimers() }
            model.fetchCode = {
                calls.count += 1
                return "code-\(calls.count)"
            }
            model.load()
            model.onAppear()
            model.onDisappear()

            _ = try await LibraryService.ensureToken { _, _ in Self.answer() }
            try await Task.sleep(for: .milliseconds(100))

            #expect(model.isLoggedIn)
            #expect(calls.count == 0)
            model.onAppear()
            try await waitUntil { model.qrPayload == "code-1" }
        }
    }

    @Test func aRefusalArmsATryForTheEndOfItsWaitThatSignsInAPageOnTheForm() async throws {
        let calls = Calls()
        let sleeper = ManualSleeper()
        let signIn: @MainActor (String, String) async throws -> LibraryLoginData = { _, _ in
            calls.count += 1
            if calls.count == 1 { throw LibraryServiceError.loginFailed("wrong password") }
            return Self.answer()
        }
        try await Self.withStoredAccount { _ in
            LibraryQRCache.shared.clear()
            _ = try? await LibraryService.ensureToken(signIn: signIn, retrySleep: { await sleeper.sleep(for: $0) })
            let model = LibraryViewModel()
            defer { model.stopTimers() }
            model.fetchCode = { "code-1" }
            model.load()
            model.onAppear()
            #expect(!model.isLoggedIn)

            let waiting = try #require(LibraryService.storedPasswordRetry)
            try await sleeper.waitUntilArmed()
            let wait = try #require(await sleeper.requestedDurations.first)
            #expect(wait > .seconds(9) && wait <= .seconds(10))

            Self.refusedOnceAndDue()
            await sleeper.fire()
            await waiting.value

            #expect(calls.count == 2)
            #expect(model.isLoggedIn)
            try await waitUntil { model.qrPayload == "code-1" }
        }
    }

    @Test func anAutomaticSignInHeldBackArmsATryForWhatIsLeftOfTheWait() async throws {
        let calls = Calls()
        let sleeper = ManualSleeper()
        try await Self.withStoredAccount { _ in
            LibraryService.storedPasswordRefusals = (2, Date().addingTimeInterval(-20))
            let signedIn = await LibraryService.signInIfCredentialed(
                signIn: { _, _ in
                    calls.count += 1
                    return Self.answer()
                },
                retrySleep: { await sleeper.sleep(for: $0) }
            )
            #expect(!signedIn)
            try await sleeper.waitUntilArmed()
            let wait = try #require(await sleeper.requestedDurations.first)
            #expect(wait > .seconds(39) && wait <= .seconds(40))

            await sleeper.fire()
            try await sleeper.waitUntilArmed(atLeast: 2)
            #expect(calls.count == 0)
        }
    }

    @Test func aTryThatCannotReachTheServerArmsALongerOne() async throws {
        let calls = Calls()
        let sleeper = ManualSleeper()
        let signIn: @MainActor (String, String) async throws -> LibraryLoginData = { _, _ in
            calls.count += 1
            switch calls.count {
            case 1: throw LibraryServiceError.loginFailed("wrong password")
            case 2: throw URLError(.notConnectedToInternet)
            default: return Self.answer()
            }
        }
        try await Self.withStoredAccount { _ in
            _ = try? await LibraryService.ensureToken(signIn: signIn, retrySleep: { await sleeper.sleep(for: $0) })
            try await sleeper.waitUntilArmed()

            Self.refusedOnceAndDue()
            await sleeper.fire()
            try await sleeper.waitUntilArmed(atLeast: 2)
            #expect(calls.count == 2)
            #expect(await sleeper.requestedDurations.last == .seconds(SSOLoginService.storedPasswordRetryDelay(afterRefusals: 2)))

            let waiting = try #require(LibraryService.storedPasswordRetry)
            await sleeper.fire()
            await waiting.value
            #expect(calls.count == 3)
            #expect(LibraryService.isTokenValid)
        }
    }

    enum HeldTryEnd: String, CaseIterable, CustomTestStringConvertible {
        case unreachable
        case refused

        var testDescription: String { rawValue }
    }

    @Test(arguments: HeldTryEnd.allCases)
    func aTypedSignInDuringATryKeepsItFromArmingAnother(end: HeldTryEnd) async throws {
        let calls = Calls()
        let sleeper = ManualSleeper()
        let held = AsyncStream<Void>.makeStream()
        let signIn: @MainActor (String, String) async throws -> LibraryLoginData = { _, _ in
            calls.count += 1
            if calls.count == 1 { throw LibraryServiceError.loginFailed("wrong password") }
            for await _ in held.stream { break }
            switch end {
            case .unreachable: throw URLError(.notConnectedToInternet)
            case .refused: throw LibraryServiceError.loginFailed("wrong password")
            }
        }
        try await Self.withStoredAccount { _ in
            let username = try #require(LibraryService.storedUsername)
            _ = try? await LibraryService.ensureToken(signIn: signIn, retrySleep: { await sleeper.sleep(for: $0) })
            let waiting = try #require(LibraryService.storedPasswordRetry)
            try await sleeper.waitUntilArmed()

            Self.refusedOnceAndDue()
            await sleeper.fire()
            try await waitUntil { calls.count == 2 }
            _ = try? await LibraryService.login(username: username, password: "typed", request: { _, _ in
                throw LibraryServiceError.loginFailed("wrong password")
            })
            held.continuation.yield()
            await waiting.value

            #expect(LibraryService.storedPasswordRetry == nil)
            #expect(await sleeper.armedCount == 1)
            #expect(LibraryService.storedPasswordRefusals.count == (end == .refused ? 2 : 1))
        }
    }

    enum RetryEnd: String, CaseIterable, CustomTestStringConvertible {
        case savedCredentials
        case signOut
        case typedSignIn

        var testDescription: String { rawValue }
    }

    @Test(arguments: RetryEnd.allCases)
    func aWaitingTryIsDroppedByNewCredentialsASignOutOrATypedSignIn(end: RetryEnd) async throws {
        let calls = Calls()
        let sleeper = ManualSleeper()
        try await Self.withStoredAccount { _ in
            let username = try #require(LibraryService.storedUsername)
            _ = try? await LibraryService.ensureToken(
                signIn: { _, _ in
                    calls.count += 1
                    throw LibraryServiceError.loginFailed("wrong password")
                },
                retrySleep: { await sleeper.sleep(for: $0) }
            )
            let waiting = try #require(LibraryService.storedPasswordRetry)

            switch end {
            case .savedCredentials:
                LibraryService.saveCredentials(username: username, password: "new")
            case .signOut:
                LibraryService.clearCredentials()
            case .typedSignIn:
                _ = try? await LibraryService.login(username: username, password: "typed", request: { _, _ in
                    throw LibraryServiceError.loginFailed("wrong password")
                })
            }
            #expect(LibraryService.storedPasswordRetry == nil)

            await sleeper.fire()
            await waiting.value
            #expect(calls.count == 1)
        }
    }

    @Test func thePauseRunsFromTheFailure() {
        let failure = Date(timeIntervalSince1970: 1_000_000)
        #expect(LibraryService.signInIsDue(lastFailure: nil, now: failure))
        #expect(!LibraryService.signInIsDue(lastFailure: failure, now: failure.addingTimeInterval(60)))
        #expect(LibraryService.signInIsDue(lastFailure: failure, now: failure.addingTimeInterval(LibraryService.signInPause)))
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
