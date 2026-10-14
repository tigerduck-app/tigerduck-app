import Foundation
import Testing
@testable import TigerDuck

/// The custom `ColorPicker` reports every step of a drag, and each applied colour writes the
/// colour map, reloads three screens and the Live Activity, and queues a sync. Only the colour
/// a drag pauses on is applied. The waits are a `ManualSleeper`, so a pause ends when the test
/// fires it.
@MainActor
struct CustomColorPickDebouncerTests {
    private final class Applied {
        var hexes: [UInt32] = []
    }

    /// The course's colour before the drag.
    private static let appliedHex: UInt32 = 0xAAAAAA

    /// A preset applies at once, and not after the account that opened the sheet signed out
    /// (https://github.com/tigerduck-app/tigerduck-app/issues/482).
    @Test func aPresetAfterASignOutSavesNothing() {
        let applied = Applied()
        var signedIn = true
        let picks = CustomColorPickDebouncer(
            apply: { applied.hexes.append($0) },
            appliedHex: { Self.appliedHex },
            isCurrent: { signedIn }
        )

        picks.select(0x111111)
        signedIn = false
        picks.select(0x222222)

        #expect(applied.hexes == [0x111111])
    }

    @Test func aDragAppliesOnlyTheColourItPausesOn() async throws {
        let applied = Applied()
        let timer = ManualSleeper()
        let picks = CustomColorPickDebouncer(
            apply: { applied.hexes.append($0) },
            appliedHex: { Self.appliedHex },
            isCurrent: { true },
            sleep: { await timer.sleep(for: $0) }
        )
        var windows: [Task<Void, Never>] = []
        for hex: UInt32 in [0x111111, 0x222222, 0x333333] {
            picks.pick(hex)
            windows.append(try #require(picks.pendingTask))
        }
        try await timer.waitUntilArmed(atLeast: 3)
        #expect(await timer.requestedDurations == [Duration](repeating: .milliseconds(300), count: 3))
        #expect(applied.hexes.isEmpty)

        // Each pick cancelled the wait before it; firing ends the last.
        await timer.fire()
        for window in windows { await window.value }

        #expect(applied.hexes == [0x333333])
    }

    @Test func closingTheSheetMidPauseAppliesTheLastColour() async throws {
        let applied = Applied()
        let timer = ManualSleeper()
        let picks = CustomColorPickDebouncer(
            apply: { applied.hexes.append($0) },
            appliedHex: { Self.appliedHex },
            isCurrent: { true },
            sleep: { await timer.sleep(for: $0) }
        )
        picks.pick(0x123456)
        let window = try #require(picks.pendingTask)

        picks.flush()
        await window.value

        #expect(applied.hexes == [0x123456])
    }

    @Test func aDragBackToTheAppliedColourDropsTheWaitingOne() async throws {
        let applied = Applied()
        let timer = ManualSleeper()
        let picks = CustomColorPickDebouncer(
            apply: { applied.hexes.append($0) },
            appliedHex: { Self.appliedHex },
            isCurrent: { true },
            sleep: { await timer.sleep(for: $0) }
        )
        picks.pick(0x123456)
        let window = try #require(picks.pendingTask)

        picks.pick(Self.appliedHex)
        await window.value
        #expect(picks.pendingTask == nil)
        // What the sheet does as it closes.
        picks.flush()

        #expect(applied.hexes.isEmpty)
    }

    @Test func showingTheAppliedColourAppliesNothing() async throws {
        // The picker reports the course's own colour when it first shows it.
        let applied = Applied()
        let picks = CustomColorPickDebouncer(
            apply: { applied.hexes.append($0) },
            appliedHex: { Self.appliedHex },
            isCurrent: { true }
        )

        picks.pick(Self.appliedHex)
        picks.flush()

        #expect(picks.pendingTask == nil)
        #expect(applied.hexes.isEmpty)
    }

    @Test func aColourStillWaitingAtSignOutIsDropped() async throws {
        let applied = Applied()
        let timer = ManualSleeper()
        var signedIn = true
        let picks = CustomColorPickDebouncer(
            apply: { applied.hexes.append($0) },
            appliedHex: { Self.appliedHex },
            isCurrent: { signedIn },
            sleep: { await timer.sleep(for: $0) }
        )
        picks.pick(0x123456)
        let window = try #require(picks.pendingTask)
        try await timer.waitUntilArmed()

        signedIn = false
        await timer.fire()
        await window.value
        // What the sheet does as it closes.
        picks.flush()

        #expect(applied.hexes.isEmpty)
    }

    @Test func aPresetDropsTheWaitingCustomColour() async throws {
        let applied = Applied()
        let timer = ManualSleeper()
        let picks = CustomColorPickDebouncer(
            apply: { applied.hexes.append($0) },
            appliedHex: { Self.appliedHex },
            isCurrent: { true },
            sleep: { await timer.sleep(for: $0) }
        )
        picks.pick(0x123456)
        let window = try #require(picks.pendingTask)

        picks.select(0x654321)
        await window.value
        // What the sheet does as it closes after the preset tap.
        picks.flush()

        #expect(applied.hexes == [0x654321])
    }
}
