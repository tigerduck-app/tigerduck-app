// `PushCoordinator.syncNow`, which a sync trigger's handler calls in the background to send the
// Live Activity schedule before it answers the push, after which iOS may suspend the app
// (https://github.com/tigerduck-app/tigerduck-app/issues/663). The backend is `SettingsAPIStub`.
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct ScheduleSendNowTests {
    private struct Backend {
        let baseURL = SettingsAPIStub.uniqueBaseURL()

        var schedule: URL { baseURL.appendingPathComponent("schedule/sync") }

        func sent() -> [URLRequest] { SettingsAPIStub.requests(for: schedule) }
    }

    private static func coordinator(_ backend: Backend) -> PushCoordinator {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        let client = PushAPIClient(
            baseURLProvider: { [baseURL = backend.baseURL] in baseURL },
            session: URLSession(configuration: config),
            authHeaderProvider: { "Bearer test" }
        )
        return PushCoordinator(identity: PushIdentity(uuid: "test-device"), apiClient: client)
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
    }

    /// A sign-out's unregister waits only for a POST already under way.
    @Test("Once a sign-out has stopped the push stack, sending now sends nothing")
    func sendingNowAfterASignOutSendsNothing() async {
        let backend = Backend()
        let push = Self.coordinator(backend)
        push.enable()
        await push.disable()

        await push.syncNow { Self.inputs }

        #expect(backend.sent().isEmpty)
    }
}
