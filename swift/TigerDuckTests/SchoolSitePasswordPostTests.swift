import Foundation
import Testing
@testable import TigerDuck

/// A school site's own post of the stored password, such as the credit program system's sign-in,
/// kept to the rules of the app's automatic posts.
@MainActor
@Suite(.serialized)
struct SchoolSitePasswordPostTests {
    /// Dates the last refusal once the defaults are this test's: waiting for them can outlast the
    /// backoff.
    private func withRefusals(_ count: Int, refusedSecondsAgo: TimeInterval?, _ body: () async -> Void) async {
        await withExclusiveRealDefaults {
            let saved = SchoolPasswordPosts.storedPasswordRefusals
            let last = refusedSecondsAgo.map { Date(timeIntervalSinceNow: -$0) }
            SchoolPasswordPosts.setStoredPasswordRefusals((count, last), for: testSignIn)
            defer { SchoolPasswordPosts.setStoredPasswordRefusals(saved, for: testSignIn) }
            await body()
        }
    }

    @Test func nothingIsPostedWhileRefusalsHaveTheAppWaiting() async {
        await withRefusals(1, refusedSecondsAgo: 0) {
            var posts = 0
            let status = await SchoolAccountSignIn.postStoredPassword(for: testSignIn) {
                posts += 1
                return 200
            }
            #expect(status == nil)
            #expect(posts == 0)
        }
    }

    @Test func aRefusalCountsTowardTheWaitAndAnAnswerTheSiteTakesDoesNot() async {
        await withRefusals(0, refusedSecondsAgo: nil) {
            #expect(await SchoolAccountSignIn.postStoredPassword(for: testSignIn) { 200 } == 200)
            #expect(SchoolPasswordPosts.storedPasswordRefusals.count == 0)
            #expect(await SchoolAccountSignIn.postStoredPassword(for: testSignIn) { 401 } == 401)
            #expect(SchoolPasswordPosts.storedPasswordRefusals.count == 1)
        }
    }

    @Test func aSignInThatEndedPostsNothing() async {
        await withRefusals(0, refusedSecondsAgo: nil) {
            var posts = 0
            let status = await SchoolAccountSignIn.postStoredPassword(for: endedTestSignIn) {
                posts += 1
                return 200
            }
            #expect(status == nil)
            #expect(posts == 0)
        }
    }
}
