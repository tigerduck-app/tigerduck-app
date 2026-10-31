import Foundation
import Observation
import Testing
@testable import TigerDuck
import TigerDuckCore

@MainActor
struct DeviceSurfaceSyncerTests {
    @Observable
    final class Inputs {
        var accent = 0x007AFF
        var preset = "default"
    }

    final class Calls {
        var widgets: [Bool] = []
        var watch = 0
        var liveActivity = 0
    }

    private let inputs = Inputs()
    private let calls = Calls()
    private let sleeper = ManualSleeper()
    private let center = NotificationCenter()

    private func makeSyncer() -> DeviceSurfaceSyncer {
        let data = AppDataRevision(courses: 0, assignments: 0, colors: 0, courseChanges: 0, calendar: .empty)
        return DeviceSurfaceSyncer(
            surfaces: .init(
                widgets: { [calls] in calls.widgets.append($0) },
                watch: { [calls] in calls.watch += 1 },
                liveActivity: { [calls] in calls.liveActivity += 1 }
            ),
            fingerprint: { [inputs] nudges in
                .init(
                    data: data, language: "zh", accentHex: inputs.accent, visualPreset: inputs.preset,
                    signedIn: true, nudges: nudges
                )
            },
            center: center,
            sleep: { [sleeper] in await sleeper.sleep(for: $0) }
        )
    }

    @Test("a burst of changes refreshes the widgets, the Watch and the Live Activity once")
    func aBurstRefreshesOnce() async throws {
        let syncer = makeSyncer()

        inputs.accent = 0xFF2D55
        try await sleeper.waitUntilArmed()
        inputs.accent = 0x34C759
        try await sleeper.waitUntilArmed(atLeast: 2)
        await sleeper.fire()

        try await waitUntil { calls.watch == 1 }
        #expect(calls.widgets == [false])
        #expect(calls.liveActivity == 1)
        #expect(await sleeper.requestedDurations == [DeviceSurfaceSyncer.debounce, DeviceSurfaceSyncer.debounce])
        withExtendedLifetime(syncer) {}
    }

    @Test("a change of the visual preset alone refreshes only the Watch")
    func aPresetChangeRefreshesOnlyTheWatch() async throws {
        let syncer = makeSyncer()

        inputs.preset = "classic"
        try await sleeper.waitUntilArmed()
        await sleeper.fire()

        try await waitUntil { calls.watch == 1 }
        #expect(calls.widgets.isEmpty)
        #expect(calls.liveActivity == 0)
        withExtendedLifetime(syncer) {}
    }

    @Test("a new locale reloads the widgets even when their snapshot stays the same")
    func aLocaleChangeForcesAWidgetReload() async throws {
        let syncer = makeSyncer()

        center.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        try await sleeper.waitUntilArmed()
        await sleeper.fire()

        try await waitUntil { calls.widgets == [true] }
        withExtendedLifetime(syncer) {}
    }

    @Test("a change undone within the debounce refreshes nothing")
    func anUndoneChangeRefreshesNothing() async throws {
        let syncer = makeSyncer()

        inputs.accent = 0xFF2D55
        try await sleeper.waitUntilArmed()
        inputs.accent = 0x007AFF
        try await sleeper.waitUntilArmed(atLeast: 2)
        await sleeper.fire()
        inputs.preset = "classic"
        try await sleeper.waitUntilArmed(atLeast: 3)
        await sleeper.fire()

        try await waitUntil { calls.watch == 1 }
        #expect(calls.widgets.isEmpty)
        withExtendedLifetime(syncer) {}
    }
}
