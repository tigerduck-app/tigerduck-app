import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct ModelStoreResetTests {

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
