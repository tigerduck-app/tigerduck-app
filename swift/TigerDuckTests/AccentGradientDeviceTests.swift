import Foundation
import Testing
import TigerDuckCore
@testable import TigerDuck

struct AccentGradientDevicePayloadTests {
    private static let gradient = AccentGradient(stops: [0x4B48D1, 0xD61F45], style: .linear, direction: .bottomToTop)!

    @Test("A widget snapshot carries the gradient it is built with, and none otherwise")
    func widgetSnapshot() throws {
        func build(_ gradient: AccentGradient?) -> WidgetSnapshot {
            WidgetSnapshotBuilder.build(.init(
                courses: [], customNames: [:], colorMap: [:], isLoggedIn: true, accentColorHex: 0x4B48D1,
                now: Date(), accentGradient: gradient
            ))
        }

        #expect(build(nil).accentGradient == nil)
        let built = build(Self.gradient)
        #expect(built.accentColorHex == 0x4B48D1)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(built))
        #expect(decoded.accentGradient == Self.gradient)
    }

    @Test("A Live Activity without a gradient encodes the keys it had before")
    func liveActivityKeysUnchanged() throws {
        var snapshot = LiveActivitySnapshot(
            scenario: .inClass, title: "Course", subtitle: "09:10", locationText: nil, instructor: nil,
            countdownTarget: nil, progressStart: nil, accentHex: 0x4B48D1, deepLink: nil, sourceId: "c_1"
        )
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
        #expect(plain?["accentGradient"] == nil)

        snapshot.accentGradient = Self.gradient
        let decoded = try JSONDecoder().decode(LiveActivitySnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.accentGradient == Self.gradient)
        #expect(decoded.accentHex == 0x4B48D1)
    }

    @Test("The Watch gets the gradient it is pushed with")
    @MainActor
    func watchSnapshot() {
        func encode(_ gradient: AccentGradient?) -> WatchSnapshot {
            WatchPayloadEncoder.encode(
                courses: [], customNames: [:], accentHex: "#4B48D1", syncedAt: Date(), loggedIn: true,
                languageTag: nil, visualPreset: .default, accentGradient: gradient
            )
        }

        #expect(encode(nil).accentGradient == nil)
        #expect(encode(Self.gradient).accentGradient == Self.gradient)
        #expect(encode(Self.gradient).accentHex == "#4B48D1")
    }
}
