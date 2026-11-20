import Foundation
import Testing
@testable import TigerDuck

@MainActor
private final class Steps {
    var taken: [String] = []
}

@MainActor
private enum RecordingStore: AccountScoped {
    static var steps: Steps?

    static func forgetAccount(in storage: AccountStorage) {
        steps?.taken.append("stores")
    }
}

@MainActor
@Suite(.serialized)
struct SignOutPlanTests {
    @Test("a sign-out stops the work, moves the session on, clears the stores, then starts its calls")
    func theStepsRunInOrder() async {
        let steps = Steps()
        RecordingStore.steps = steps
        defer { RecordingStore.steps = nil }
        let session = AccountSession()
        let signIn = session.signIns.currentSignIn
        let work = session.task { _ in }

        let calls = SignOutPlan(
            session: session,
            stores: [RecordingStore.self],
            stopWork: { steps.taken.append(work.isCancelled ? "stop" : "stop with work running") },
            endSession: { _ in
                steps.taken.append(signIn.isCurrent ? "end before the move" : "end")
                return {
                    steps.taken.append("calls")
                    return Task {}
                }
            },
            clearMemoryState: { steps.taken.append("rest") }
        ).run()

        #expect(steps.taken == ["stop", "end", "stores", "rest", "calls"])
        #expect(calls != nil)
        #expect(!signIn.isCurrent)
    }

    @Test("a course deletion made before a sign-out hides nothing of the next sign-in, which keeps its own")
    func courseDeletionsEndWithTheSignIn() {
        let session = AccountSession()
        let deletedAt = Date()
        let edits = LocalEdits()
        edits.setRecentCourseDeletions(["CS1001": deletedAt], for: session.currentSignIn)
        #expect(edits.recentCourseDeletions == ["CS1001": deletedAt])

        SignOutPlan(session: session, stores: []).run()

        #expect(edits.recentCourseDeletions.isEmpty)
        edits.setRecentCourseDeletions(["CS1002": deletedAt], for: session.currentSignIn)
        #expect(edits.recentCourseDeletions == ["CS1002": deletedAt])
    }
}

@MainActor
struct AccountSessionTests {
    @Test("a sign-in stays current until its session ends it, and only for its own session")
    func aSignInBelongsToOneSession() {
        let school = AccountSession()
        let library = AccountSession()
        let signIn = school.signIns.currentSignIn

        library.endSignIn()
        #expect(signIn.isCurrent)

        let next = school.endSignIn()
        #expect(!signIn.isCurrent)
        #expect(next.isCurrent)
        #expect(next == school.signIns.currentSignIn)
    }

    @Test("stopping the work cancels the scoped tasks of the sign-in, which see their ticket go stale")
    func stoppingTheWorkCancelsItsTasks() async {
        let session = AccountSession()
        let steps = Steps()
        let (started, start) = AsyncStream<Void>.makeStream()
        let task = session.task { ticket in
            start.finish()
            try? await Task.sleep(for: .seconds(60))
            steps.taken.append(Task.isCancelled ? "cancelled" : "slept")
            steps.taken.append(ticket.isCurrent ? "current" : "stale")
        }
        for await _ in started {}

        session.endSignIn()
        session.endSignIn()
        await task.value

        #expect(steps.taken == ["cancelled", "stale"])
    }
}
