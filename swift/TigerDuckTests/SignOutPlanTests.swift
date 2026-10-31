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
        let signIn = session.ticket
        let work = session.task { _ in }

        let calls = SignOutPlan(
            session: session,
            stores: [RecordingStore.self],
            stopWork: { steps.taken.append(work.isCancelled ? "stop" : "stop with work running") },
            endSession: {
                steps.taken.append(session.isCurrent(signIn) ? "end before the move" : "end")
                return {
                    steps.taken.append("calls")
                    return Task {}
                }
            },
            clearRest: { steps.taken.append("rest") }
        ).run()

        #expect(steps.taken == ["stop", "end", "stores", "rest", "calls"])
        #expect(calls != nil)
        #expect(!session.isCurrent(signIn))
    }

    @Test("a course deletion made before a sign-out hides nothing of the next sign-in, which keeps its own")
    func courseDeletionsEndWithTheSignIn() {
        let session = AccountSession()
        let deletedAt = Date()
        var deletions = SignInScoped<[String: Date]>(empty: [:])
        deletions.set(["CS1001": deletedAt], in: session)
        #expect(deletions.value(in: session) == ["CS1001": deletedAt])

        SignOutPlan(session: session, stores: []).run()

        #expect(deletions.value(in: session).isEmpty)
        deletions.set(["CS1002": deletedAt], in: session)
        #expect(deletions.value(in: session) == ["CS1002": deletedAt])
    }
}

@MainActor
struct AccountSessionTests {
    @Test("a ticket stays current until the session moves on, and only for its own session")
    func ticketsBelongToOneSignIn() {
        let school = AccountSession()
        let library = AccountSession()
        let signIn = school.ticket
        let check = school.currentCheck()

        library.moveOn()
        #expect(school.isCurrent(signIn))
        #expect(check())

        school.moveOn()
        #expect(!school.isCurrent(signIn))
        #expect(!check())
        #expect(school.isCurrent(school.ticket))
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
            steps.taken.append(session.isCurrent(ticket) ? "current" : "stale")
        }
        for await _ in started {}

        session.stopWork()
        session.moveOn()
        await task.value

        #expect(steps.taken == ["cancelled", "stale"])
    }
}
