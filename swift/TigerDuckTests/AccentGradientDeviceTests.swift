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

    @Test("A gradient this build cannot read leaves the rest of a widget or Live Activity snapshot", arguments: [
        #"{"stops":[1,2],"style":"spiral","direction":"leftToRight"}"#,
        #"{"stops":[1,2],"style":"linear","direction":"sideways"}"#,
        #"{"stops":[],"style":"linear","direction":"leftToRight"}"#,
        #"{"stops":[1,2,3,4,5,6],"style":"linear","direction":"leftToRight"}"#,
    ])
    func unreadableGradient(json: String) throws {
        let gradient = try JSONSerialization.jsonObject(with: Data(json.utf8))
        func replacingGradient<T: Codable>(of value: T) throws -> T {
            var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
            object["accentGradient"] = gradient
            return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
        }

        let activity = try replacingGradient(of: LiveActivitySnapshot(
            scenario: .inClass, title: "Course", subtitle: "09:10", locationText: nil, instructor: nil,
            countdownTarget: nil, progressStart: nil, accentHex: 0x4B48D1, deepLink: nil, sourceId: "c_1"
        ))
        #expect(activity.accentGradient == nil)
        #expect(activity.accentHex == 0x4B48D1)

        let widget = try replacingGradient(of: WidgetSnapshotBuilder.build(.init(
            courses: [], customNames: [:], colorMap: [:], isLoggedIn: true, accentColorHex: 0x4B48D1, now: Date()
        )))
        #expect(widget.accentGradient == nil)
        #expect(widget.accentColorHex == 0x4B48D1)
    }

    @Test("A Live Activity start push with five stops and long names stays under APNs' 4 KB")
    func liveActivityPushFits() throws {
        var snapshot = LiveActivitySnapshot(
            scenario: .assignmentUrgent, title: String(repeating: "課", count: 64), subtitle: String(repeating: "時", count: 48),
            locationText: String(repeating: "室", count: 32), instructor: String(repeating: "師", count: 32),
            countdownTarget: Date(), progressStart: Date(), accentHex: 0xFFFFFF,
            deepLink: URL(string: "tigerduck://course/" + String(repeating: "x", count: 64)),
            sourceId: String(repeating: "s", count: 64), roomChanged: true, timeChanged: true
        )
        snapshot.accentGradient = AccentGradient(
            stops: Array(repeating: 0xFFFFFF, count: 5), style: .angular, direction: .bottomRightToTopLeft
        )
        let state = try JSONEncoder().encode(TigerDuckActivityAttributes.ContentState(snapshot: snapshot))
        // The start push repeats the title and subtitle as its alert, beside the activity id, its
        // dates and the keys around them, which aioapns writes with spaces after each separator.
        let alert = snapshot.title.utf8.count + snapshot.subtitle.utf8.count
        let envelope = 512

        #expect(state.count + alert + envelope < 4096, "\(state.count) + \(alert) + \(envelope)")
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
