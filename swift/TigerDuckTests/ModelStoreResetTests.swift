import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct ModelStoreResetTests {

    /// SQLite writes its sidecars as `default.store-wal` and `default.store-shm`, and they must go
    /// with the store, or the retry after a failed open reads the same stale data.
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

    private struct OpenFailed: Error {}

    private static func storeFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelStoreResetTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func aStoreThatDoesNotOpenYetIsKeptAndThisLaunchUsesMemory() throws {
        let dir = try Self.storeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = dir.appendingPathComponent("default.store")
        try Data("kept".utf8).write(to: store)
        // Mode 000 stands in for the lock before the first unlock: the file is there and does not open.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.path) }
        var diskOpens = 0

        let opened = TigerDuckApp.openStore(at: store) { inMemory in
            if inMemory { return "memory" }
            diskOpens += 1
            throw OpenFailed()
        }

        #expect(opened == "memory")
        #expect(diskOpens == 1)
        #expect(FileManager.default.fileExists(atPath: store.path))
    }

    @Test func aStoreThatOpensButFailsIsMadeAgain() throws {
        let dir = try Self.storeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = dir.appendingPathComponent("default.store")
        try Data("damaged".utf8).write(to: store)
        var diskOpens = 0

        let opened = TigerDuckApp.openStore(at: store) { inMemory in
            if inMemory { return "memory" }
            diskOpens += 1
            guard !FileManager.default.fileExists(atPath: store.path) else { throw OpenFailed() }
            return "disk"
        }

        #expect(opened == "disk")
        #expect(diskOpens == 2)
    }
}
