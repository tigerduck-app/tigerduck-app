import Foundation
import Testing
@testable import TigerDuck

/// A school site's own post of the stored password, such as the credit program system's sign-in,
/// kept to the rules of the app's automatic posts.
@MainActor
@Suite(.serialized)
struct SchoolSitePasswordPostTests {
    private func withRefusals(_ count: Int, last: Date?, _ body: () async -> Void) async {
        await withExclusiveRealDefaults {
            let saved = SchoolPasswordPosts.storedPasswordRefusals
            SchoolPasswordPosts.setStoredPasswordRefusals((count, last), for: testSignIn)
            defer { SchoolPasswordPosts.setStoredPasswordRefusals(saved, for: testSignIn) }
            await body()
        }
    }

    @Test func nothingIsPostedWhileRefusalsHaveTheAppWaiting() async {
        await withRefusals(1, last: Date()) {
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
        await withRefusals(0, last: nil) {
            #expect(await SchoolAccountSignIn.postStoredPassword(for: testSignIn) { 200 } == 200)
            #expect(SchoolPasswordPosts.storedPasswordRefusals.count == 0)
            #expect(await SchoolAccountSignIn.postStoredPassword(for: testSignIn) { 401 } == 401)
            #expect(SchoolPasswordPosts.storedPasswordRefusals.count == 1)
        }
    }

    @Test func aSignInThatEndedPostsNothing() async {
        await withRefusals(0, last: nil) {
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
