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
        var deviceAccents = AppPreferences.DeviceAccents()
        var preset = "default"
        var language = "zh-Hant"
    }

    final class Calls {
        var widgets: [Bool] = []
        var watch = 0
        var liveActivity: [Bool] = []
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
                liveActivity: { [calls] in calls.liveActivity.append($0) }
            ),
            fingerprint: { [inputs] unobserved in
                .init(
                    data: data, language: inputs.language, accentHex: inputs.accent, deviceAccents: inputs.deviceAccents,
                    visualPreset: inputs.preset, signedIn: true, unobserved: unobserved
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
        #expect(calls.liveActivity == [false])
        #expect(await sleeper.requestedDurations == [DeviceSurfaceSyncer.debounce, DeviceSurfaceSyncer.debounce])
        withExtendedLifetime(syncer) {}
    }

    @Test("a gradient sent to one device, keeping its first stop, refreshes all three")
    func aDeviceGradientRefreshesEverySurface() async throws {
        let syncer = makeSyncer()

        inputs.deviceAccents.watch = AccentGradient(stops: [0x007AFF, 0xAF52DE])
        try await sleeper.waitUntilArmed()
        await sleeper.fire()

        try await waitUntil { calls.watch == 1 }
        #expect(calls.widgets == [false])
        #expect(calls.liveActivity == [false])
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
        #expect(calls.liveActivity.isEmpty)
        withExtendedLifetime(syncer) {}
    }

    @Test("a new locale reloads the widgets and redraws the running Live Activities")
    func aLocaleChangeForcesAWidgetReload() async throws {
        let syncer = makeSyncer()

        center.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        try await sleeper.waitUntilArmed()
        await sleeper.fire()

        try await waitUntil { calls.widgets == [true] }
        #expect(calls.liveActivity == [true])
        withExtendedLifetime(syncer) {}
    }

    @Test("a new app language reloads the widgets and redraws the running Live Activities")
    func anAppLanguageChangeForcesAWidgetReload() async throws {
        let syncer = makeSyncer()

        inputs.language = LanguageManager.system
        try await sleeper.waitUntilArmed()
        await sleeper.fire()

        try await waitUntil { calls.widgets == [true] }
        #expect(calls.liveActivity == [true])
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
