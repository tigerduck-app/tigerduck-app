import Foundation
import os
import Testing
@testable import TigerDuck

@MainActor
struct SyncClockTests {
    nonisolated final class StoredReadings: Sendable {
        private let readings: OSAllocatedUnfairLock<SyncClock.Readings>
        private let emptyReads: OSAllocatedUnfairLock<Int>

        init(_ readings: SyncClock.Readings = .init(), emptyReads: Int = 0) {
            self.readings = OSAllocatedUnfairLock(initialState: readings)
            self.emptyReads = OSAllocatedUnfairLock(initialState: emptyReads)
        }

        var stored: SyncClock.Readings { readings.withLock { $0 } }

        var storage: SyncClock.Storage {
            SyncClock.Storage(
                load: {
                    let readsEmpty = self.emptyReads.withLock { left in
                        defer { left = max(left - 1, 0) }
                        return left > 0
                    }
                    return readsEmpty ? .init() : self.readings.withLock { $0 }
                },
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
    static let year = 365 * 24 * 60 * minute
    static let laterThanAnyRun: Int64 = 4_000_000_000_000_000

    static func makeClock(_ device: DeviceClock, _ stored: StoredReadings = StoredReadings()) -> SyncClock {
        SyncClock(storage: stored.storage, now: { device.now })
    }

    private static func clock(of date: Date) -> Int64 { PushAPI.clock(of: date) }

    @Test("An edit is stamped one tick after the latest of the device clock, the server clock seen and the last stamp")
    func stampsAfterTheLatestOfTheThree() async {
        let device = DeviceClock(Self.ten)
        let clock = Self.makeClock(device)
        #expect(Self.clock(of: clock.stamp()) == Self.ten + 1)

        clock.hear(Self.ten + 5 * Self.minute)
        #expect(Self.clock(of: clock.stamp()) == Self.ten + 5 * Self.minute + 1)

        let issuedLater = Self.makeClock(DeviceClock(Self.ten), StoredReadings(.init(lastIssued: Self.ten + 60 * Self.minute)))
        #expect(Self.clock(of: issuedLater.stamp()) == Self.ten + 60 * Self.minute + 1)
    }

    @Test("A fetch's read of the next mark sits between the marks before and after it, with the backend behind or ahead", arguments: [Int64(-60), 10])
    func lowestNextMarkSitsBetweenMarks(backendMinutesAhead: Int64) async {
        let device = DeviceClock(Self.ten)
        let clock = Self.makeClock(device)
        clock.hear(Self.ten + backendMinutesAhead * Self.minute)

        let before = clock.mark()
        let reading = clock.lowestNextMark
        let after = clock.mark()

        #expect(before >= device.now)
        #expect(before <= reading)
        #expect(reading <= after)
        #expect(Self.clock(of: after) >= clock.readings.lastIssued)
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
        heard.hear(Self.ten)
        #expect(Self.clock(of: heard.stamp()) == Self.ten + 5 * Self.second + 1)

        device.set(Self.ten + Self.minute + 10 * Self.second)
        #expect(Self.clock(of: heard.stamp()) == Self.ten + 15 * Self.second + 1)
    }

    @Test("An edit after the backend is heard is still stamped after one issued before it, while the cap is below that")
    func capNeverLowersTheLastStamp() async {
        let clock = Self.makeClock(DeviceClock(Self.ten + Self.minute))
        let beforeHearing = Self.clock(of: clock.stamp())

        clock.hear(Self.ten)

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

    @Test("An earlier answer read late keeps the last server value seen, and one further ahead than any answer could be gives way")
    func lastSeenGivesWayOnlyWhenFarAhead() async {
        let stored = StoredReadings()
        let clock = Self.makeClock(DeviceClock(Self.ten), stored)

        clock.hear(Self.ten + Self.minute)
        clock.hear(Self.ten)
        #expect(clock.readings.lastSeen == Self.ten + Self.minute)

        clock.hear(Self.ten + Self.year)
        clock.hear(Self.ten)
        #expect(clock.readings.lastSeen == Self.ten)
        #expect(Self.makeClock(DeviceClock(Self.ten), stored).readings.lastSeen == Self.ten)
        #expect(clock.readings.heard == SyncClock.Heard(clock: Self.ten, arrivedAt: Self.ten))
    }

    @Test("A header before TigerSync existed or far past any real time is not heard", arguments: [Int64(1), 0, -5, 1_000_000_000_000_000_000, .max])
    func brokenHeaderIsIgnored(header: Int64) async {
        let clock = Self.makeClock(DeviceClock(Self.ten), StoredReadings(.init(lastIssued: Self.ten, lastSeen: Self.ten)))

        clock.hear(header)

        #expect(clock.readings == SyncClock.Readings(lastIssued: Self.ten, lastSeen: Self.ten))
        #expect(Self.clock(of: clock.stamp()) == Self.ten + 1)
    }

    @Test("A device clock set a year ahead and back stamps within the backend's reach again once the backend answers")
    func clockSetAheadAndBackRecovers() async {
        let device = DeviceClock(Self.ten)
        let clock = Self.makeClock(device)
        clock.hear(Self.ten)
        device.set(Self.ten + Self.year)
        _ = clock.stamp()

        clock.hear(Self.ten + Self.minute)
        #expect(Self.clock(of: clock.stamp()) == Self.ten + Self.minute + SyncClock.backendLead + 1)

        device.set(Self.ten + 2 * Self.minute)
        clock.hear(Self.ten + 2 * Self.minute)
        #expect(Self.clock(of: clock.stamp()) == Self.ten + 2 * Self.minute + 1)
    }

    @Test("A pull-back moves a time kept from before it under its ceiling in its order, and leaves one near or under the ceiling")
    func pullBackMovesKeptTimesUnderItsCeiling() throws {
        let device = DeviceClock(Self.ten + Self.year)
        let clock = Self.makeClock(device)
        let kept = [clock.stamp(), clock.stamp()]
        device.set(Self.ten)

        let pullBack = try #require(clock.hear(Self.ten))
        let fresh = clock.stamp()
        let earlier = PushAPI.date(ofClock: Self.ten - Self.minute)

        #expect(kept.map { Self.clock(of: pullBack.restamped($0)) } == [Self.ten + SyncClock.backendLead - 1, Self.ten + SyncClock.backendLead])
        #expect(Self.clock(of: fresh) == Self.ten + SyncClock.backendLead + 1)
        #expect(pullBack.restamped(fresh) == fresh)
        #expect(pullBack.restamped(earlier) == earlier)
        #expect(clock.hear(Self.ten) == nil)
    }

    @Test("Stored values that read back missing or unreadable never produce a stamp at or before one already issued")
    func unreadableStoredValuesFailClosed() {
        let device = DeviceClock(Self.ten)
        let forgetful = Self.makeClock(device, StoredReadings(emptyReads: .max))
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

    @Test("A save after a read that found the store empty lowers no value the store holds")
    func aSaveAfterAnEmptyReadLowersNothing() {
        let held = SyncClock.Readings(
            lastIssued: Self.ten + Self.minute, lastSeen: Self.ten + Self.minute,
            heard: SyncClock.Heard(clock: Self.ten, arrivedAt: Self.ten)
        )
        let stored = StoredReadings(held, emptyReads: 1)

        _ = Self.makeClock(DeviceClock(Self.ten), stored).stamp()

        #expect(stored.stored == SyncClock.Readings(lastIssued: Self.ten + Self.minute, lastSeen: Self.ten + Self.minute, heard: held.heard))
    }

    @Test("A clock value up to the year 2100 survives the outbox's Date unchanged")
    func clockValuesRoundTripThroughDate() {
        var generator = SystemRandomNumberGenerator()
        let values = (0..<10_000).map { _ in Int64.random(in: 0...4_100_000_000_000_000, using: &generator) }

        #expect(values.filter { Self.clock(of: PushAPI.date(ofClock: $0)) != $0 }.isEmpty)
    }

    @Test("A 2xx or 409 answer raises the last server value seen and records when it arrived, and another status does not")
    func okAndConflictAnswersAreHeard() async throws {
        let device = DeviceClock(Self.ten)
        let clock = Self.makeClock(device)
        let (client, baseURL) = Self.stubbedClient(clock)
        let revision = baseURL.appendingPathComponent("sync/revision")
        SettingsAPIStub.enqueue(.init(
            statusCode: 200, body: Data(#"{"revision":1}"#.utf8), headerFields: ["X-TigerSync-Clock": String(Self.ten + Self.minute)]
        ), for: revision)
        SettingsAPIStub.enqueue(.init(
            statusCode: 404, body: Data(#"{"error":"not_found","message":"gone"}"#.utf8),
            headerFields: ["X-TigerSync-Clock": String(Self.ten + 3 * Self.minute)]
        ), for: revision)
        SettingsAPIStub.enqueue(.init(
            statusCode: 409, body: Data(#"{"error":"sync_revision_expired","message":"expired"}"#.utf8),
            headerFields: ["X-TigerSync-Clock": String(Self.ten + 2 * Self.minute)]
        ), for: revision)

        _ = try await client.fetchRevision(for: testSignIn)
        #expect(clock.readings.lastSeen == Self.ten + Self.minute)
        device.set(Self.ten + Self.second)
        await #expect(throws: PushAPIError.self) { try await client.fetchRevision(for: testSignIn) }
        #expect(clock.readings.lastSeen == Self.ten + Self.minute)
        await #expect(throws: PushAPIError.self) { try await client.fetchRevision(for: testSignIn) }

        #expect(clock.readings.lastSeen == Self.ten + 2 * Self.minute)
        #expect(clock.readings.heard == SyncClock.Heard(clock: Self.ten + 2 * Self.minute, arrivedAt: Self.ten + Self.second))
    }

    @Test("An answer from another host than the client's backend is not heard: a request sent to another server, or a departing session's")
    func otherServersAreNotHeard() async throws {
        let clock = Self.makeClock(DeviceClock(Self.ten))
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let other = URL(string: "https://other-stub.invalid/\(UUID().uuidString)/v4")!
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        let client = { (auth: BackendAuth) in
            PushAPIClient(
                baseURLProvider: { AuthTokenManager.departing?.baseURL ?? baseURL }, session: URLSession(configuration: config),
                auth: auth, clock: clock
            )
        }
        let heard = ["X-TigerSync-Clock": String(Self.ten + Self.minute)]
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data("{}".utf8), headerFields: heard),
                                for: other.appendingPathComponent("devices/test-device"))
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data(#"{"revision":1}"#.utf8), headerFields: heard),
                                for: other.appendingPathComponent("sync/revision"))

        try await client(.unbound { "Bearer test" }).unregisterDevice(deviceId: "test-device", at: other)
        _ = try await AuthTokenManager.$departing.withValue(.init(accessToken: "A1", baseURL: other)) {
            try await client(.signedIn { "Bearer test" }).fetchRevision(for: testSignIn)
        }

        #expect(SettingsAPIStub.requests(under: other).count == 2)
        #expect(clock.readings == SyncClock.Readings())
    }

    static func backendAnswers(_ clock: SyncClock, at serverClock: Int64) async throws {
        let (client, baseURL) = stubbedClient(clock)
        SettingsAPIStub.enqueue(.init(
            statusCode: 200, body: Data(#"{"revision":1}"#.utf8), headerFields: ["X-TigerSync-Clock": String(serverClock)]
        ), for: baseURL.appendingPathComponent("sync/revision"))
        _ = try await client.fetchRevision(for: testSignIn)
    }

    static func stubbedClient(_ clock: SyncClock) -> (PushAPIClient, URL) {
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
        SyncClock(storage: SyncClockTests.StoredReadings().storage)
    }
}
