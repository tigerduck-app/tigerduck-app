import Foundation
import os
import Testing
@testable import TigerDuck

@MainActor
struct SyncClockTests {
    nonisolated final class StoredReadings: Sendable {
        private let readings: OSAllocatedUnfairLock<SyncClock.Readings>
        private let forgets: Bool

        init(_ readings: SyncClock.Readings = .init(), forgets: Bool = false) {
            self.readings = OSAllocatedUnfairLock(initialState: readings)
            self.forgets = forgets
        }

        var storage: SyncClock.Storage {
            SyncClock.Storage(
                load: { self.forgets ? .init() : self.readings.withLock { $0 } },
                save: { new in self.readings.withLock { $0 = new } }
            )
        }
    }

    nonisolated final class DeviceClock: Sendable {
        private let reading: OSAllocatedUnfairLock<Int64>

        init(_ clock: Int64) { reading = OSAllocatedUnfairLock(initialState: clock) }

        var now: Date { PushAPI.date(ofClock: reading.withLock { $0 }) }
        func set(_ clock: Int64) { reading.withLock { $0 = clock } }
    }

    static let ten: Int64 = 1_790_000_000_000_000
    static let second: Int64 = 1_000_000
    static let minute = 60 * second
    static let laterThanAnyRun: Int64 = 4_000_000_000_000_000

    static func makeClock(
        _ device: DeviceClock, _ stored: StoredReadings = StoredReadings(), readable: Bool = true
    ) -> SyncClock {
        SyncClock(storage: stored.storage, now: { device.now }, protectedDataReadable: { readable })
    }

    private static func clock(of date: Date) -> Int64 { PushAPI.clock(of: date) }

    @Test("An edit is stamped one tick after the latest of the device clock, the server clock seen and the last stamp")
    func stampsAfterTheLatestOfTheThree() async {
        let device = DeviceClock(Self.ten)
        let clock = Self.makeClock(device)
        #expect(Self.clock(of: clock.stamp()) == Self.ten + 1)

        await clock.hear(Self.ten + 5 * Self.minute)
        #expect(Self.clock(of: clock.stamp()) == Self.ten + 5 * Self.minute + 1)

        let issuedLater = Self.makeClock(DeviceClock(Self.ten), StoredReadings(.init(lastIssued: Self.ten + 60 * Self.minute)))
        #expect(Self.clock(of: issuedLater.stamp()) == Self.ten + 60 * Self.minute + 1)
    }

    @Test("Two edits made before the device clock moves are a microsecond apart on the wire")
    func twoEditsInOneMicrosecond() {
        let clock = Self.makeClock(DeviceClock(Self.ten))

        let first = Self.clock(of: clock.stamp())
        let second = Self.clock(of: clock.stamp())

        #expect(first == Self.ten + 1)
        #expect(second == first + 1)
        #expect(clock.readings.lastIssued == second)
        #expect(Self.clock(of: clock.lowestNextStamp) == second + 1)
    }

    @Test("A device clock a minute ahead stamps uncapped until it hears the backend, then five seconds past the backend's time")
    func clockAheadIsCappedOnceTheBackendIsHeard() async {
        let device = DeviceClock(Self.ten + Self.minute)
        let unheard = Self.makeClock(device)
        #expect(Self.clock(of: unheard.stamp()) == Self.ten + Self.minute + 1)

        let heard = Self.makeClock(device)
        await heard.hear(Self.ten)
        #expect(Self.clock(of: heard.stamp()) == Self.ten + 5 * Self.second + 1)

        device.set(Self.ten + Self.minute + 10 * Self.second)
        #expect(Self.clock(of: heard.stamp()) == Self.ten + 15 * Self.second + 1)
    }

    @Test("An edit after the backend is heard is still stamped after one issued before it, while the cap is below that")
    func capNeverLowersTheLastStamp() async {
        let clock = Self.makeClock(DeviceClock(Self.ten + Self.minute))
        let beforeHearing = Self.clock(of: clock.stamp())

        await clock.hear(Self.ten)

        #expect(Self.clock(of: clock.stamp()) == beforeHearing + 1)
        #expect(clock.readings.lastSeen == Self.ten)
    }

    @Test("After a relaunch on a clock set back, the next edit is stamped after the last one issued")
    func relaunchKeepsTheLastStamp() {
        let stored = StoredReadings()
        let device = DeviceClock(Self.ten)
        let issued = Self.clock(of: Self.makeClock(device, stored).stamp())

        device.set(Self.ten - 60 * Self.minute)
        let relaunched = Self.makeClock(device, stored)

        #expect(Self.clock(of: relaunched.stamp()) == issued + 1)
    }

    @Test("The last server value seen never drops, and an implausible header is ignored")
    func lastSeenNeverDrops() async {
        let stored = StoredReadings()
        let clock = Self.makeClock(DeviceClock(Self.ten), stored)

        await clock.hear(Self.ten + 10 * Self.minute)
        await clock.hear(Self.ten)
        await clock.hear(Int64.max)
        await clock.hear(0)

        #expect(clock.readings.lastSeen == Self.ten + 10 * Self.minute)
        #expect(Self.makeClock(DeviceClock(Self.ten), stored).readings.lastSeen == Self.ten + 10 * Self.minute)
        #expect(clock.readings.heard == SyncClock.Heard(clock: Self.ten, arrivedAt: Self.ten))
    }

    @Test("Stored values that read back missing or unreadable never produce a stamp at or before one already issued")
    func unreadableStoredValuesFailClosed() {
        let device = DeviceClock(Self.ten)
        let forgetful = Self.makeClock(device, StoredReadings(forgets: true))
        let first = Self.clock(of: forgetful.stamp())
        device.set(Self.ten - Self.minute)
        #expect(Self.clock(of: forgetful.stamp()) == first + 1)

        let brokenHeader = StoredReadings(.init(heard: SyncClock.Heard(clock: Self.ten, arrivedAt: .min)))
        let uncapped = Self.makeClock(DeviceClock(Self.ten + Self.minute), brokenHeader)
        #expect(Self.clock(of: uncapped.stamp()) == Self.ten + Self.minute + 1)

        let pastAnyRealTime = Self.makeClock(DeviceClock(Self.ten), StoredReadings(.init(lastIssued: .max, lastSeen: .max)))
        _ = pastAnyRealTime.stamp()
        #expect(pastAnyRealTime.readings.lastIssued == Int64.max / 2)
    }

    @Test("A clock value up to the year 2100 survives the outbox's Date unchanged")
    func clockValuesRoundTripThroughDate() {
        var generator = SystemRandomNumberGenerator()
        let values = (0..<10_000).map { _ in Int64.random(in: 0...4_100_000_000_000_000, using: &generator) }

        #expect(values.filter { Self.clock(of: PushAPI.date(ofClock: $0)) != $0 }.isEmpty)
    }

    @Test("Every backend answer raises the last server value seen and records when it arrived, an error answer too")
    func everyAnswerIsHeard() async throws {
        let device = DeviceClock(Self.ten)
        let clock = Self.makeClock(device)
        let (client, baseURL) = Self.stubbedClient(clock)
        SettingsAPIStub.enqueue(.init(
            statusCode: 200, body: Data(#"{"revision":1}"#.utf8), headerFields: ["X-TigerSync-Clock": String(Self.ten + Self.minute)]
        ), for: baseURL.appendingPathComponent("sync/revision"))
        SettingsAPIStub.enqueue(.init(
            statusCode: 404, body: Data(#"{"error":"not_found","message":"gone"}"#.utf8),
            headerFields: ["X-TigerSync-Clock": String(Self.ten + 2 * Self.minute)]
        ), for: baseURL.appendingPathComponent("sync/revision"))

        _ = try await client.fetchRevision(for: testSignIn)
        #expect(clock.readings.lastSeen == Self.ten + Self.minute)
        device.set(Self.ten + Self.second)
        await #expect(throws: PushAPIError.self) { try await client.fetchRevision(for: testSignIn) }

        #expect(clock.readings.lastSeen == Self.ten + 2 * Self.minute)
        #expect(clock.readings.heard == SyncClock.Heard(clock: Self.ten + 2 * Self.minute, arrivedAt: Self.ten + Self.second))
    }

    @Test("A header that arrives while protected data is unavailable changes nothing")
    func headerIsIgnoredWhileProtectedDataIsUnavailable() async throws {
        let stored = StoredReadings(.init(lastIssued: Self.ten, lastSeen: Self.ten))
        let clock = Self.makeClock(DeviceClock(Self.ten), stored, readable: false)
        let (client, baseURL) = Self.stubbedClient(clock)
        SettingsAPIStub.enqueue(.init(
            statusCode: 200, body: Data(#"{"revision":1}"#.utf8), headerFields: ["X-TigerSync-Clock": String(Self.ten + Self.minute)]
        ), for: baseURL.appendingPathComponent("sync/revision"))

        _ = try await client.fetchRevision(for: testSignIn)

        #expect(clock.readings == SyncClock.Readings(lastIssued: Self.ten, lastSeen: Self.ten))
    }

    private static func stubbedClient(_ clock: SyncClock) -> (PushAPIClient, URL) {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        let client = PushAPIClient(
            baseURLProvider: { baseURL }, session: URLSession(configuration: config), auth: .signedIn { "Bearer test" },
            clock: clock
        )
        return (client, baseURL)
    }
}

extension SyncClock {
    static func isolated() -> SyncClock {
        SyncClock(storage: SyncClockTests.StoredReadings().storage, protectedDataReadable: { true })
    }
}
