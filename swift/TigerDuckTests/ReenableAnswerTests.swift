import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct ReenableAnswerTests {
    private static func conflict(
        _ categories: [String], serverIgnoredCourses: [AppState.ServerIgnoredCourse]? = nil
    ) -> AppState.ReenableConflict {
        AppState.ReenableConflict(
            categories: categories, description: "", serverIgnoredCourses: serverIgnoredCourses,
            serverMarkedAssignments: []
        )
    }

    @Test("Use Local lets go of what it holds only once each edit it queued is in the outbox")
    func useLocalReleasesOnceItsEditsAreQueued() async {
        let app = AnswerProbe(pending: ["course_colors", "assignments"])
        app.queueEdits = {
            ["colour", "mark"].map { edit in
                Task {
                    await Task.yield()
                    app.events.append("queued \(edit)")
                }
            }
        }

        await AppState.answerReenableConflict(
            Self.conflict(["course_colors", "assignments"]), keepLocal: true, effects: app.effects
        )

        #expect(Set(app.events.prefix(2)) == ["queued colour", "queued mark"])
        #expect(app.events.dropFirst(2) == ["release", "end", "answered"])
        #expect(app.pending.isEmpty)
        #expect(app.hold == AppState.UseLocalHold())
    }

    @Test("Use Local for courses keeps them pending until its course requests are done")
    func useLocalKeepsCoursesPendingUntilTheirRequestsAreDone() async {
        let app = AnswerProbe(pending: ["courses"])
        app.sendCourses = { app.events.append("courses sent, pending: \(app.pending.sorted())") }

        await AppState.answerReenableConflict(Self.conflict(["courses"]), keepLocal: true, effects: app.effects)

        #expect(app.events == [#"courses sent, pending: ["courses"]"#, "release", "end", "answered"])
        #expect(app.pending.isEmpty)
    }

    @Test("Course requests that fail keep the courses pending, and the rest is let go of")
    func failedCourseRequestsKeepTheCoursesPending() async {
        let app = AnswerProbe(pending: ["courses", "course_names"])
        app.sendCourses = { throw URLError(.notConnectedToInternet) }

        await AppState.answerReenableConflict(
            Self.conflict(["courses", "course_names"]), keepLocal: true, effects: app.effects
        )

        #expect(app.events == ["marked courses", "release", "end", "answered after a failed save"])
        #expect(app.pending == ["courses"])
        #expect(app.hold == AppState.UseLocalHold())
    }

    @Test("A sign-out while Use Local queues its edits ends the hold and lets go of nothing of the next account's")
    func signOutWhileQueueingLetsGoOfNothing() async {
        let app = AnswerProbe(pending: ["course_colors"])
        app.queueEdits = { [Task { app.signOut(nextAccountPending: ["course_colors"]) }] }

        await AppState.answerReenableConflict(Self.conflict(["course_colors"]), keepLocal: true, effects: app.effects)

        #expect(app.events == ["end"])
        #expect(app.pending == ["course_colors"])
        #expect(app.hold == AppState.UseLocalHold())
    }

    @Test("A sign-out during the course requests queues nothing, marks nothing and lets go of nothing")
    func signOutDuringTheCourseRequestsStopsTheAnswer() async {
        let app = AnswerProbe(pending: ["courses", "assignments"])
        app.sendCourses = {
            app.signOut(nextAccountPending: ["assignments"])
            throw CancellationError()
        }
        app.queueEdits = {
            app.events.append("queued")
            return []
        }

        await AppState.answerReenableConflict(
            Self.conflict(["courses", "assignments"]), keepLocal: true, effects: app.effects
        )

        #expect(app.events == ["end"])
        #expect(app.pending == ["assignments"])
        #expect(app.hold == AppState.UseLocalHold())
    }

    @Test("Use Server drops the queued edits of what it answers before it takes them off the pending list and the server's data")
    func useServerDropsTheQueuedEditsFirst() async {
        let app = AnswerProbe(pending: ["course_colors", "assignments", "courses"])
        app.dropQueuedEdits = { categories, courseIgnores in
            app.events.append("dropped \(categories.sorted()) courseIgnores: \(courseIgnores) pending: \(app.pending.sorted())")
        }

        await AppState.answerReenableConflict(
            Self.conflict(["course_colors", "assignments"], serverIgnoredCourses: []), keepLocal: false,
            effects: app.effects
        )

        #expect(app.events == [
            #"dropped ["assignments", "course_colors"] courseIgnores: true pending: ["assignments", "course_colors", "courses"]"#,
            "local copies dropped", "server sync, after one running: true", "answered",
        ])
        #expect(app.pending == ["courses"])
    }

    @Test("Use Server on a check that compared no course settings leaves the queued ones")
    func useServerKeepsCourseSettingsTheCheckDidNotCompare() async {
        let app = AnswerProbe(pending: ["assignments"])
        app.dropQueuedEdits = { _, courseIgnores in app.events.append("courseIgnores: \(courseIgnores)") }

        await AppState.answerReenableConflict(Self.conflict(["assignments"]), keepLocal: false, effects: app.effects)

        #expect(app.events.first == "courseIgnores: false")
    }

    @Test("A sign-out while Use Server drops the queued edits writes nothing more")
    func signOutWhileUseServerDropsWritesNothing() async {
        let app = AnswerProbe(pending: ["course_names"])
        app.dropQueuedEdits = { _, _ in app.signOut(nextAccountPending: ["course_names"]) }

        await AppState.answerReenableConflict(Self.conflict(["course_names"]), keepLocal: false, effects: app.effects)

        #expect(app.events.isEmpty)
        #expect(app.pending == ["course_names"])
    }

    @Test("A sign-out during Use Server's sync leaves the check's retry to the next account")
    func signOutDuringUseServersSyncSettlesNothing() async {
        let app = AnswerProbe(pending: ["course_names"])
        app.syncFromServer = { app.signOut(nextAccountPending: []) }

        await AppState.answerReenableConflict(Self.conflict(["course_names"]), keepLocal: false, effects: app.effects)

        #expect(app.events == ["local copies dropped", "server sync, after one running: true"])
    }
}

@MainActor
private final class AnswerProbe {
    var pending: Set<String>
    var hold = AppState.UseLocalHold()
    var events: [String] = []
    var sendCourses: () async throws -> Void = {}
    var queueEdits: () -> [Task<Void, Never>] = { [] }
    var dropQueuedEdits: (Set<String>, Bool) async -> Void = { _, _ in }
    var syncFromServer: () async -> Void = {}
    private var signedIn = true

    init(pending: Set<String>) {
        self.pending = pending
    }

    func signOut(nextAccountPending: Set<String>) {
        signedIn = false
        pending = nextAccountPending
    }

    var effects: AppState.ReenableAnswerEffects {
        AppState.ReenableAnswerEffects(
            isCurrent: { self.signedIn },
            take: { self.hold.take($0, keepLocal: $1, from: &self.pending) },
            release: {
                self.events.append("release")
                self.hold.release($0, from: &self.pending)
            },
            end: {
                self.events.append("end")
                self.hold.end($0)
            },
            dropQueuedEdits: { await self.dropQueuedEdits($0, $1) },
            sendCourses: { try await self.sendCourses() },
            markCoursesForCheck: {
                self.events.append("marked courses")
                self.pending.insert("courses")
                self.hold.noteReenabled("courses")
            },
            queueEdits: { self.queueEdits() },
            dropLocalCopies: { self.events.append("local copies dropped") },
            syncFromServer: { followUpIfBusy in
                await self.syncFromServer()
                self.events.append("server sync, after one running: \(followUpIfBusy)")
            },
            noteAnswered: { self.events.append($0 ? "answered after a failed save" : "answered") }
        )
    }
}
