import Foundation
import Testing
import UIKit
@testable import TigerDuck

@MainActor
struct ScheduleSendNowTests {
    private struct Backend {
        let baseURL = SettingsAPIStub.uniqueBaseURL()

        var schedule: URL { baseURL.appendingPathComponent("schedule/sync") }

        func sent() -> [URLRequest] { SettingsAPIStub.requests(for: schedule) }
    }

    private static func coordinator(
        _ backend: Backend, isProtectedDataAvailable: (@MainActor () -> Bool)? = nil
    ) -> PushCoordinator {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        // A held reply must outlast a main actor held for over a minute by other tests.
        config.timeoutIntervalForRequest = 600
        let client = PushAPIClient(
            baseURLProvider: { [baseURL = backend.baseURL] in baseURL },
            session: URLSession(configuration: config),
            authHeaderProvider: { "Bearer test" }
        )
        return PushCoordinator(
            identity: PushIdentity(uuid: "test-device"), apiClient: client,
            isProtectedDataAvailable: isProtectedDataAvailable
        )
    }

    private static let inputs = ScheduleSyncService.Inputs(
        courses: [],
        assignments: [],
        accentHex: 0x007AFF,
        classPreparingLeadTime: 0,
        assignmentLeadTime: 0,
        showClassPreparing: false,
        showInClass: false,
        showAssignmentScenario: false,
        liveActivityAvailable: false,
        term: "1151"
    )

    @Test("Sending now posts the schedule and returns once its reply is in")
    func sendingNowWaitsForTheReply() async throws {
        let backend = Backend()
        let reply = SettingsAPIStub.ReplyGate()
        SettingsAPIStub.enqueue(
            .init(statusCode: 200, body: Data(#"{"pending":0,"replaced":0}"#.utf8), gate: reply), for: backend.schedule
        )
        let push = Self.coordinator(backend)
        push.enable()
        var returned = false

        let send = Task {
            await push.syncNow { Self.inputs }
            returned = true
        }
        try await waitUntil(timeout: .seconds(5)) { backend.sent().count == 1 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!returned)

        reply.open()
        await send.value
        #expect(backend.sent().count == 1)
        await push.disable()
    }

    @Test("Once a sign-out has stopped the push stack, sending now sends nothing")
    func sendingNowAfterASignOutSendsNothing() async {
        let backend = Backend()
        let push = Self.coordinator(backend)
        push.enable()
        await push.disable()

        await push.syncNow { Self.inputs }

        #expect(backend.sent().isEmpty)
    }

    /// Behind the lock screen the caches read as empty, and the server cancels every start of this
    /// device that the list it is sent leaves out
    /// (https://github.com/tigerduck-app/tigerduck-backend/blob/dev/server/routes/schedule_v3.py).
    @Test("Behind the lock screen, sending now sends nothing")
    func sendingNowBehindTheLockScreenSendsNothing() async {
        let backend = Backend()
        let push = Self.coordinator(backend, isProtectedDataAvailable: { false })
        push.enable()

        await push.syncNow { Self.inputs }

        #expect(backend.sent().isEmpty)
        await push.disable()
    }

    private static let ok = SettingsAPIStub.StubResponse(statusCode: 200, body: Data(#"{"pending":0,"replaced":0}"#.utf8))

    /// An assignment due in three hours, which the list starts a Live Activity for.
    private static func inputsWithAnAssignmentDue() -> ScheduleSyncService.Inputs {
        let due = SDAssignment(
            assignmentId: "a-\(UUID().uuidString)", courseNo: "CS101", courseName: "Algorithms", title: "Lab",
            dueDate: Date().addingTimeInterval(3 * 3600)
        )
        return ScheduleSyncService.Inputs(
            courses: [], assignments: [due], accentHex: 0x007AFF, classPreparingLeadTime: 0,
            assignmentLeadTime: 3600, showClassPreparing: false, showInClass: false, showAssignmentScenario: true,
            liveActivityAvailable: true, term: "1151"
        )
    }

    @Test("Sending now the list the server last took sends nothing; a changed list goes")
    func anUnchangedListIsNotSentAgain() async throws {
        let backend = Backend()
        SettingsAPIStub.enqueue(Self.ok, for: backend.schedule)
        SettingsAPIStub.enqueue(Self.ok, for: backend.schedule)
        let push = Self.coordinator(backend)
        push.enable()

        await push.syncNow { Self.inputs }
        await push.syncNow { Self.inputs }
        #expect(backend.sent().count == 1)

        let changed = Self.inputsWithAnAssignmentDue()
        await push.syncNow { changed }
        #expect(backend.sent().count == 2)
        await push.disable()
    }

    @Test("A list the server answered with an error goes again")
    func aRefusedListGoesAgain() async {
        let backend = Backend()
        SettingsAPIStub.enqueue(.init(statusCode: 500, body: Data()), for: backend.schedule)
        SettingsAPIStub.enqueue(Self.ok, for: backend.schedule)
        let push = Self.coordinator(backend)
        push.enable()

        await push.syncNow { Self.inputs }
        await push.syncNow { Self.inputs }

        #expect(backend.sent().count == 2)
        await push.disable()
    }

    @Test("After a sign-out and back, the same list goes again")
    func theSameListGoesAfterASignOut() async {
        let backend = Backend()
        SettingsAPIStub.enqueue(Self.ok, for: backend.schedule)
        SettingsAPIStub.enqueue(Self.ok, for: backend.schedule)
        let push = Self.coordinator(backend)
        push.enable()
        await push.syncNow { Self.inputs }

        await push.disable()
        push.enable()
        await push.syncNow { Self.inputs }

        #expect(backend.sent().count == 2)
        await push.disable()
    }

    private final class TokenSource: PushTokenSource {
        var forwardToken: ((Data) -> Void)?
        var forwardError: ((Error) -> Void)?
        var onSyncTrigger: (() async -> FullSyncOutcome)?
    }

    @Test("After a sign-in or a new push token, the same list goes again")
    func theSameListGoesAfterARegistration() async {
        let backend = Backend()
        for _ in 0..<3 { SettingsAPIStub.enqueue(Self.ok, for: backend.schedule) }
        let push = Self.coordinator(backend)
        let tokens = TokenSource()
        push.bindTokenForwarding(tokens)
        push.enable()
        await push.syncNow { Self.inputs }

        push.refreshRegistrationAfterAuth()
        await push.syncNow { Self.inputs }
        #expect(backend.sent().count == 2)

        tokens.forwardToken?(Data([1, 2, 3]))
        await push.syncNow { Self.inputs }
        #expect(backend.sent().count == 3)
        await push.disable()
    }

    @Test("A sign-in while a send waits for its reply still has the next list sent")
    func aSendThatEndsAfterASignInDoesNotCountForIt() async throws {
        let backend = Backend()
        let reply = SettingsAPIStub.ReplyGate()
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Self.ok.body, gate: reply), for: backend.schedule)
        SettingsAPIStub.enqueue(Self.ok, for: backend.schedule)
        let push = Self.coordinator(backend)
        push.enable()
        let send = Task { await push.syncNow { Self.inputs } }
        try await waitUntil(timeout: .seconds(5)) { backend.sent().count == 1 }

        push.refreshRegistrationAfterAuth()
        reply.open()
        await send.value
        await push.syncNow { Self.inputs }

        #expect(backend.sent().count == 2)
        await push.disable()
    }

    @Test("A sync trigger's handler sends the schedule only after a sync that synced, with the app in the background",
          arguments: [FullSyncOutcome.synced, .skipped, .failed],
          [UIApplication.State.background, .inactive, .active])
    func theHandlerSendsOnlyAfterASyncInTheBackground(outcome: FullSyncOutcome, state: UIApplication.State) {
        #expect(AppState.sendsScheduleAfterSyncTrigger(outcome: outcome, applicationState: state)
            == (outcome == .synced && state == .background))
    }
}
