#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

/// What a tapped push opens, read from the keys the backend puts in the payload. Its standard
/// alerts send every extra key as a string.
@MainActor
struct PushTapRoutingTests {

    // MARK: - Bulletins

    @Test func aSubscriptionBulletinOpensTheBulletin() {
        let link = AppState.bulletinDeepLink(from: ["kind": "bulletin", "bulletin_id": "4821"])
        #expect(link == .bulletin(4821))
    }

    @Test func aCustomPushBulletinOpensTheBulletin() {
        // A Double-tagged NSNumber, which `as? Int` does not accept.
        let link = AppState.bulletinDeepLink(
            from: ["kind": "custom_push_bulletin", "bulletin_id": NSNumber(value: 77.0)]
        )
        #expect(link == .bulletin(77))
    }

    @Test func otherKindsAndBadIdsOpenNoBulletin() {
        #expect(AppState.bulletinDeepLink(from: ["kind": "custom_push_popup", "bulletin_id": 1]) == nil)
        #expect(AppState.bulletinDeepLink(from: ["kind": "bulletin"]) == nil)
        #expect(AppState.bulletinDeepLink(from: ["kind": "bulletin", "bulletin_id": "abc"]) == nil)
    }
}
#endif
