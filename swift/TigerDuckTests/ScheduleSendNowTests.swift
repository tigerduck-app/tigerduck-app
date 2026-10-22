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

    @Test("Behind the lock screen, sending now sends nothing")
    func sendingNowBehindTheLockScreenSendsNothing() async {
        let backend = Backend()
        let push = Self.coordinator(backend, isProtectedDataAvailable: { false })
        push.enable()

        await push.syncNow { Self.inputs }

        #expect(backend.sent().isEmpty)
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
