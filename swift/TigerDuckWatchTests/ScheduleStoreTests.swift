import XCTest
import WatchKit
@testable import TigerDuckWatch

final class ScheduleStoreTests: XCTestCase {

    private var tempDir: URL!
    private var snapshotFile: URL!
    private var defaults: UserDefaults!
    private let suiteName = "ScheduleStoreTests"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        snapshotFile = tempDir.appendingPathComponent("schedule.json")
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func sampleSnapshot() -> WatchSnapshot {
        WatchSnapshot(
            courses: [],
            accentHex: "#FF8800",
            syncedAtMs: 1_747_000_000_000,
            loggedIn: true,
            languageTag: nil
        )
    }

    @MainActor
    func test_persist_writesDecodableFile() throws {
        let store = ScheduleStore(snapshotFileURL: snapshotFile, defaults: defaults, widgetReloader: {})
        try store.persist(sampleSnapshot())
        let data = try Data(contentsOf: snapshotFile)
        let decoded = try JSONDecoder().decode(WatchSnapshot.self, from: data)
        XCTAssertEqual(decoded, sampleSnapshot())
    }

    @MainActor
    func test_loadFromDisk_returnsLastWrittenSnapshot() throws {
        let store = ScheduleStore(snapshotFileURL: snapshotFile, defaults: defaults, widgetReloader: {})
        try store.persist(sampleSnapshot())

        let fresh = ScheduleStore(snapshotFileURL: snapshotFile, defaults: defaults, widgetReloader: {})
        XCTAssertEqual(fresh.snapshot, sampleSnapshot())
    }

    @MainActor
    func test_loadFromDisk_missingFile_snapshotIsNil() {
        let store = ScheduleStore(snapshotFileURL: snapshotFile, defaults: defaults, widgetReloader: {})
        XCTAssertNil(store.snapshot)
    }

    @MainActor
    func test_shouldRequestSync_respectsTenMinuteCooldown() {
        let store = ScheduleStore(snapshotFileURL: snapshotFile, defaults: defaults, widgetReloader: {})
        let now = Date()
        store.recordSyncRequest(at: now)
        XCTAssertFalse(store.shouldRequestSync(at: now.addingTimeInterval(60)))
        XCTAssertTrue(store.shouldRequestSync(at: now.addingTimeInterval(601)))
    }

    @MainActor
    func test_shouldRequestSync_neverRequestedYet_returnsTrue() {
        let store = ScheduleStore(snapshotFileURL: snapshotFile, defaults: defaults, widgetReloader: {})
        XCTAssertTrue(store.shouldRequestSync(at: Date()))
    }
}
