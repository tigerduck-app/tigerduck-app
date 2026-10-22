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

    @Test func aRoundOfTheSignedInAccountRecordsItsAnswer() {
        let auth = Self.signedOutAuth()
        let tracker = ServerStatusTracker()

        AppServiceBridge.record(.failed, for: .courseSelection, round: auth.loginGeneration, authService: auth, tracker: tracker)

        #expect(tracker.status(for: .courseSelection) == .failed)
    }
}
