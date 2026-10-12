import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct ModelStoreResetTests {

    /// SQLite writes its sidecars as `default.store-wal` and `default.store-shm`. A reset that
    /// deleted `default.store.wal` instead left them, and the retry read the same stale data.
    @Test func resetDeletesTheStoreAndItsSQLiteSidecars() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelStoreResetTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["default.store", "default.store-wal", "default.store-shm", "other.store"] {
            try Data("stale".utf8).write(to: dir.appendingPathComponent(name))
        }

        TigerDuckApp.deleteStoreFiles(at: dir.appendingPathComponent("default.store"))

        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(left == ["other.store"])
    }
}
