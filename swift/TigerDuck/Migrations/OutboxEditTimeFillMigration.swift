import Foundation

/// Gives each queued and parked outbox entry an earlier build wrote the time it was queued as its
/// edit time, by the wall clock. It runs before the outbox first reads its files; a file the
/// locked phone keeps unreadable waits for the next launch.
enum OutboxEditTimeFillMigration {
    private static let doneKey = "OutboxEditTimeFillMigration.v1.done"

    static func runIfNeeded(directory: URL = OutboxFiles.defaultDirectory()) {
        guard !AppUserDefaults.standard.bool(forKey: doneKey) else { return }
        for name in [OutboxFiles.fileName, OutboxFiles.parkedFileName] {
            guard fill(directory.appendingPathComponent(name)) else { return }
        }
        AppUserDefaults.standard.set(true, forKey: doneKey)
    }

    /// False while the file exists but cannot be read.
    private static func fill(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        guard let data = try? Data(contentsOf: url) else { return false }
        guard var entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return true }
        var filled = false
        for index in entries.indices where entries[index]["madeAt"] == nil {
            guard let op = entries[index]["op"] as? [String: Any],
                  let stamp = op.values.lazy.compactMap({ ($0 as? [String: Any])?["stamp"] }).first else { continue }
            entries[index]["madeAt"] = ["wall": stamp]
            filled = true
        }
        guard filled, let rewritten = try? JSONSerialization.data(withJSONObject: entries) else { return true }
        return (try? rewritten.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])) != nil
    }
}
