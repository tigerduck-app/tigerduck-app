import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct ReenableAnswerTests {
    private static func conflict(
        _ categories: [SyncCategory], serverIgnoredCourses: [CourseIgnoresReconciler.ServerIgnoredCourse]? = nil
    ) -> SyncConflicts.ReenableConflict {
        SyncConflicts.ReenableConflict(
            categories: categories, description: "", serverIgnoredCourses: serverIgnoredCourses,
            serverMarkedAssignments: []
        )
    }

    @Test("Use Local lets go of what it holds only once each edit it queued is in the outbox")
    func useLocalReleasesOnceItsEditsAreQueued() async {
        let app = AnswerProbe(pending: [.courseColors, .assignments])
        app.queueEdits = {
            ["colour", "mark"].map { edit in
                Task {
                    await Task.yield()
                    app.events.append("queued \(edit)")
                }
            }
        }

        await SyncConflicts.answerReenableConflict(
            Self.conflict([.courseColors, .assignments]), keepLocal: true, effects: app.effects
        )

        #expect(Set(app.events.prefix(2)) == ["queued colour", "queued mark"])
        #expect(app.events.dropFirst(2) == ["release", "end", "answered"])
        #expect(app.pending.isEmpty)
        #expect(app.hold == SyncConflicts.UseLocalHold())
    }

    @Test("Use Local for courses keeps them pending until its course requests are done")
    func useLocalKeepsCoursesPendingUntilTheirRequestsAreDone() async {
        let app = AnswerProbe(pending: [.courses])
        app.sendCourses = { app.events.append("courses sent, pending: \(app.pending.logged)") }

        await SyncConflicts.answerReenableConflict(Self.conflict([.courses]), keepLocal: true, effects: app.effects)

        #expect(app.events == [#"courses sent, pending: ["courses"]"#, "release", "end", "answered"])
        #expect(app.pending.isEmpty)
    }

    @Test("Course requests that fail, or wait as course sync went off, keep the courses pending, and the rest is let go of",
          arguments: [URLError(.notConnectedToInternet), ResendHeldError()] as [any Error])
    func failedCourseRequestsKeepTheCoursesPending(_ failure: any Error) async {
        let app = AnswerProbe(pending: [.courses, .courseNames])
        app.sendCourses = { throw failure }

        await SyncConflicts.answerReenableConflict(
            Self.conflict([.courses, .courseNames]), keepLocal: true, effects: app.effects
        )

        #expect(app.events == ["marked courses", "release", "end", "answered after a failed save"])
        #expect(app.pending == [.courses])
        #expect(app.hold == SyncConflicts.UseLocalHold())
    }

    @Test("A sign-out while Use Local queues its edits ends the hold and lets go of nothing of the next account's")
    func signOutWhileQueueingLetsGoOfNothing() async {
        let app = AnswerProbe(pending: [.courseColors])
        app.queueEdits = { [Task { app.signOut(nextAccountPending: [.courseColors]) }] }

        await SyncConflicts.answerReenableConflict(Self.conflict([.courseColors]), keepLocal: true, effects: app.effects)

        #expect(app.events == ["end"])
        #expect(app.pending == [.courseColors])
        #expect(app.hold == SyncConflicts.UseLocalHold())
    }

    @Test("A sign-out during the course requests queues nothing, marks nothing and lets go of nothing")
    func signOutDuringTheCourseRequestsStopsTheAnswer() async {
        let app = AnswerProbe(pending: [.courses, .assignments])
        app.sendCourses = {
            app.signOut(nextAccountPending: [.assignments])
            throw CancellationError()
        }
        app.queueEdits = {
            app.events.append("queued")
            return []
        }

        await SyncConflicts.answerReenableConflict(
            Self.conflict([.courses, .assignments]), keepLocal: true, effects: app.effects
        )

        #expect(app.events == ["end"])
        #expect(app.pending == [.assignments])
        #expect(app.hold == SyncConflicts.UseLocalHold())
    }

    @Test("Use Server drops the queued edits of what it answers before it takes them off the pending list and the server's data")
    func useServerDropsTheQueuedEditsFirst() async {
        let app = AnswerProbe(pending: [.courseColors, .assignments, .courses])
        app.dropQueuedEdits = { categories, courseIgnores in
            app.events.append("dropped \(categories.logged) courseIgnores: \(courseIgnores) pending: \(app.pending.logged)")
        }

        await SyncConflicts.answerReenableConflict(
            Self.conflict([.courseColors, .assignments], serverIgnoredCourses: []), keepLocal: false,
            effects: app.effects
        )

        #expect(app.events == [
            #"dropped ["assignments", "course_colors"] courseIgnores: true pending: ["assignments", "course_colors", "courses"]"#,
            "local copies dropped", "server sync, after one running: true", "answered",
        ])
        #expect(app.pending == [.courses])
    }

    @Test("Use Server on a check that compared no course settings leaves the queued ones")
    func useServerKeepsCourseSettingsTheCheckDidNotCompare() async {
        let app = AnswerProbe(pending: [.assignments])
        app.dropQueuedEdits = { _, courseIgnores in app.events.append("courseIgnores: \(courseIgnores)") }

        await SyncConflicts.answerReenableConflict(Self.conflict([.assignments]), keepLocal: false, effects: app.effects)

        #expect(app.events.first == "courseIgnores: false")
    }

    @Test("A sign-out while Use Server drops the queued edits writes nothing more")
    func signOutWhileUseServerDropsWritesNothing() async {
        let app = AnswerProbe(pending: [.courseNames])
        app.dropQueuedEdits = { _, _ in app.signOut(nextAccountPending: [.courseNames]) }

        await SyncConflicts.answerReenableConflict(Self.conflict([.courseNames]), keepLocal: false, effects: app.effects)

        #expect(app.events.isEmpty)
        #expect(app.pending == [.courseNames])
    }

    @Test("Use Local for courses sends back the names of every course held, fetched, added by hand or hidden, as the term resets clear them")
    func useLocalSendsBackTheNamesTheResetsClear() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReenableAnswerTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let courses = CourseStore(folders: CacheFolders(root: root))
        courses.saveCourses([
            SDCourse(courseNo: "CS1", courseName: "CS1", moodleIdNumber: "1151CS1-M", semester: "1151"),
            SDCourse(courseNo: "EE2", courseName: "EE2", semester: "1151"),
            SDCourse(courseNo: "PE4", courseName: "PE4", moodleIdNumber: "1151PE4-M", semester: "1151"),
        ], semester: "1151", for: testSignIn)
        courses.saveUserAddedCourses([SDCourse(courseNo: "GE3", courseName: "GE3", semester: "1151")], for: testSignIn)
        courses.saveDeletedCourseNos(["1151:PE4"], for: testSignIn)
        courses.saveCourseCustomNames(
            ["CS1": ["en": "Code"], "EE2": ["zh": "Circuits", "en": ""], "GE3": ["en": "Art"], "PE4": ["en": "Gym"], "XX9": ["en": "Gone"]],
            for: testSignIn
        )
        let resend = { (categories: Set<SyncCategory>, syncsNames: Bool) in
            ReenableAnswer.courseOverridesToResend(
                for: categories, syncsNames: syncsNames, terms: ["1151"], courses: courses,
                colors: ["CS1": 0xFF0000, "GE3": 0x00FF00, "PE4": 0x0000FF, "XX9": 0x111111]
            )
        }

        let afterReset = resend([.courses, .courseColors], true)
        #expect(Set(afterReset.names.map { "\($0.identity) \($0.locale) \($0.name)" })
            == ["1151CS1-M en Code", "1151EE2 zh Circuits", "1151GE3 en Art", "1151PE4-M en Gym"])
        #expect(Set(afterReset.colors.map { "\($0.identity) \($0.colorHex)" })
            == ["1151CS1-M #FF0000", "1151GE3 #00FF00", "1151PE4-M #0000FF"])
        #expect(resend([.courses, .courseColors], false).names.isEmpty)
        #expect(Set(resend([.courseNames], false).names.map { $0.identity }) == ["1151CS1-M", "1151EE2", "1151GE3", "1151PE4-M"])
        #expect(resend([.assignments], true).names.isEmpty)
    }

    @Test("A sign-out during Use Server's sync leaves the check's retry to the next account")
    func signOutDuringUseServersSyncSettlesNothing() async {
        let app = AnswerProbe(pending: [.courseNames])
        app.syncFromServer = { app.signOut(nextAccountPending: []) }

        await SyncConflicts.answerReenableConflict(Self.conflict([.courseNames]), keepLocal: false, effects: app.effects)

        #expect(app.events == ["local copies dropped", "server sync, after one running: true"])
    }
}

@MainActor
private final class AnswerProbe {
    var pending: Set<SyncCategory>
    var hold = SyncConflicts.UseLocalHold()
    var events: [String] = []
    var sendCourses: () async throws -> Void = {}
    var queueEdits: () -> [Task<Void, Never>] = { [] }
    var dropQueuedEdits: (Set<SyncCategory>, Bool) async -> Void = { _, _ in }
    var syncFromServer: () async -> Void = {}
    private let session = AccountSession()
    private let signIn: SignIn

    init(pending: Set<SyncCategory>) {
        self.pending = pending
        signIn = session.signIns.currentSignIn
    }

    func signOut(nextAccountPending: Set<SyncCategory>) {
        session.endSignIn()
        pending = nextAccountPending
    }

    var effects: SyncConflicts.ReenableAnswerEffects {
        SyncConflicts.ReenableAnswerEffects(
            signIn: signIn,
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
                self.pending.insert(.courses)
                self.hold.noteReenabled(.courses)
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
