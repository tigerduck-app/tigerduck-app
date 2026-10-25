#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct BrowserSignInTests {
    private static let page = URL(string: "https://moodle2.ntust.edu.tw/user/edit.php")!
    private static let other = URL(string: "https://moodle2.ntust.edu.tw/my/")!
    private static let keyLink = URL(string: "https://moodle2.ntust.edu.tw/admin/tool/mobile/autologin.php?key=k")!

    private final class Steps {
        var taken: [String] = []
        var loaded: [URL] = []
        var keys: [URL?] = []
        var sessions: [Bool] = []
        var hasSession = false
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private static func signIn(_ steps: Steps) -> BrowserSignIn {
        let signIn = BrowserSignIn(
            hasSession: { steps.hasSession },
            signedInURL: { _ in
                steps.taken.append("key")
                return steps.keys.isEmpty ? nil : steps.keys.removeFirst()
            },
            signInWithSession: {
                steps.taken.append("session")
                return steps.sessions.isEmpty ? false : steps.sessions.removeFirst()
            },
            now: { steps.clock }
        )
        signIn.load = { steps.loaded.append($0) }
        return signIn
    }

    @Test func aMoodlePageWithoutASessionSignsInWithTheKeyFirst() async {
        let steps = Steps()
        steps.keys = [Self.keyLink]
        let signIn = Self.signIn(steps)

        await signIn.open(Self.page)
        #expect(signIn.phase == .working)
        await signIn.settle()

        #expect(steps.taken == ["key"])
        #expect(steps.loaded == [Self.keyLink])
        signIn.pageSettled()
        #expect(signIn.phase == .idle)
    }

    @Test func aSessionTheBrowserHoldsLoadsThePageAtOnce() async {
        let steps = Steps()
        steps.hasSession = true
        let signIn = Self.signIn(steps)

        await signIn.open(Self.page)

        #expect(steps.taken.isEmpty)
        #expect(steps.loaded == [Self.page])
        #expect(signIn.phase == .idle)
    }

    @Test func pagesOutsideMoodleNeedNoSignIn() async {
        let steps = Steps()
        let signIn = Self.signIn(steps)
        let library = URL(string: "https://www.lib.ntust.edu.tw/")!

        await signIn.open(library)

        #expect(steps.taken.isEmpty)
        #expect(steps.loaded == [library])
    }

    @Test func withoutAKeyTheSSOSessionSignsInAndThePageLoads() async {
        let steps = Steps()
        steps.sessions = [true]
        let signIn = Self.signIn(steps)

        await signIn.open(Self.page)
        await signIn.settle()

        #expect(steps.taken == ["key", "session"])
        #expect(steps.loaded == [Self.page])
        #expect(signIn.phase == .working)
    }

    @Test func aKeyMoodleRefusesFallsBackToTheSSOSession() async {
        let steps = Steps()
        steps.keys = [Self.keyLink]
        steps.sessions = [true]
        let signIn = Self.signIn(steps)
        await signIn.open(Self.page)
        await signIn.settle()

        steps.clock += 5
        signIn.reachedSignInPage(returningTo: Self.keyLink)
        await signIn.settle()

        #expect(steps.taken == ["key", "session"])
        #expect(steps.loaded == [Self.keyLink, Self.page])
    }

    @Test func bothFailedShowsTheFailureWithoutLooping() async {
        let steps = Steps()
        steps.sessions = [true]
        let signIn = Self.signIn(steps)
        await signIn.open(Self.page)
        await signIn.settle()

        // Signed in, yet Moodle sends the page to its sign-in again.
        signIn.reachedSignInPage(returningTo: Self.page)
        await signIn.settle()

        #expect(signIn.phase == .failed)
        #expect(steps.taken == ["key", "session"])
        #expect(steps.loaded == [Self.page])
    }

    @Test func noKeyAndNoSessionFails() async {
        let steps = Steps()
        let signIn = Self.signIn(steps)

        await signIn.open(Self.page)
        await signIn.settle()

        #expect(signIn.phase == .failed)
        #expect(steps.loaded.isEmpty)
    }

    @Test func retryStartsOverWithTheKey() async {
        let steps = Steps()
        let signIn = Self.signIn(steps)
        await signIn.open(Self.page)
        await signIn.settle()
        steps.taken = []
        steps.keys = [Self.keyLink]

        signIn.retry()
        await signIn.settle()

        #expect(steps.taken == ["key"])
        #expect(steps.loaded == [Self.keyLink])
    }

    @Test func aSessionThatEndsLaterSignsInAgainForThePageItWasGoingTo() async {
        let steps = Steps()
        steps.sessions = [true, true]
        let signIn = Self.signIn(steps)
        await signIn.open(Self.page)
        await signIn.settle()
        signIn.pageSettled()

        steps.clock += BrowserSignIn.retryWindow + 1
        signIn.reachedSignInPage(returningTo: Self.other)
        #expect(signIn.phase == .working)
        await signIn.settle()

        #expect(steps.taken == ["key", "session", "key", "session"])
        #expect(steps.loaded == [Self.page, Self.other])
    }

    @Test func closingTheBrowserCancelsTheSessionSignInUnderWay() async {
        let steps = Steps()
        let signIn = Self.signIn(steps)
        let started = AsyncStream<Void>.makeStream()
        signIn.signInWithSession = {
            started.continuation.yield()
            while !Task.isCancelled { await Task.yield() }
            steps.taken.append("cancelled")
            return true
        }
        await signIn.open(Self.page)
        for await _ in started.stream { break }

        signIn.cancel()
        await signIn.settle()
        while !steps.taken.contains("cancelled") { await Task.yield() }

        #expect(steps.loaded.isEmpty)
        #expect(signIn.phase == .idle)
    }

    @Test func aSignInPageReachedWhileASignInRunsChangesNothing() async {
        let steps = Steps()
        steps.sessions = [true]
        let signIn = Self.signIn(steps)
        await signIn.open(Self.page)

        signIn.reachedSignInPage(returningTo: Self.other)
        await signIn.settle()

        #expect(steps.taken == ["key", "session"])
        #expect(steps.loaded == [Self.page])
    }
}
#endif
