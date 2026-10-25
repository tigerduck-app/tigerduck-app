import Defaults
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct BridgeStatusRecordTests {
    private static func signedOutAuth() -> AuthService {
        AuthService(keychainHasCredentials: { false }, notificationCenter: NotificationCenter())
    }

    @Test func aRoundFromBeforeASignOutRecordsNothing() {
        let auth = Self.signedOutAuth()
        let tracker = ServerStatusTracker()

        AppServiceBridge.record(.failed, for: .moodle, round: auth.loginGeneration &- 1, authService: auth, tracker: tracker)

        #expect(tracker.status(for: .moodle) == .unknown)
    }

    #if DEBUG
    @Test("a Moodle round a sign-out overtook leaves the shared status as it was")
    func aMoodleRoundASignOutOvertookRecordsNothing() async {
        await withExclusiveRealDefaults {
            let saved = (Defaults[.ntustCredentialsPresent], SSOLoginService.storedPasswordRefusals)
            let savedStatus = ServerStatusTracker.shared.status(for: .moodle)
            defer {
                Defaults[.ntustCredentialsPresent] = saved.0
                SSOLoginService.storedPasswordRefusals = saved.1
                ServerStatusTracker.shared.set(savedStatus, for: .moodle)
            }
            let auth = AuthService(
                keychainHasCredentials: { false },
                notificationCenter: NotificationCenter(),
                moodleTokens: MoodleTokenService(
                    storedCredentials: { nil }, tokens: .init(load: { nil }, save: { _ in }, drop: {}),
                    harvest: { _, _ in throw CancellationError() }
                ),
                endSchoolSession: { _ in }
            )
            #if os(iOS)
            auth.accountNotifications = DeliveredNotificationsStub()
            #endif
            let simulator = ServerFailureSimulator()
            simulator.failures[.moodle] = .timeout
            simulator.sleep = { _ in await MainActor.run { auth.logout() } }
            ServerStatusTracker.shared.set(.ok, for: .moodle)

            await SecureStore.$sharedForTesting.withValue(MemoryKeychain.signedIn()) {
                await ServerFailureSimulator.$sharedForTesting.withValue(simulator) {
                    _ = await AppServiceBridge.fetchAssignments(authService: auth)
                }
            }

            #expect(ServerStatusTracker.shared.status(for: .moodle) == .ok)
        }
    }
    #endif

    @Test func aRoundOfTheSignedInAccountRecordsItsAnswer() {
        let auth = Self.signedOutAuth()
        let tracker = ServerStatusTracker()

        AppServiceBridge.record(.failed, for: .courseSelection, round: auth.loginGeneration, authService: auth, tracker: tracker)

        #expect(tracker.status(for: .courseSelection) == .failed)
    }
}
