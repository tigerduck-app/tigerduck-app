import Foundation

/// School requests a fetch has in flight at once. Past the per-host connection limit they
/// queue, and each one's timeout runs while it waits.
nonisolated let maxConcurrentRequests = 4

func concurrentMap<Item: Sendable, Output: Sendable>(
    _ items: [Item],
    limit: Int = maxConcurrentRequests,
    _ transform: @escaping @Sendable (Item) async -> Output
) async -> [Output] {
    await withTaskGroup(of: (Int, Output).self) { group in
        var results = [Output?](repeating: nil, count: items.count)
        for (index, item) in items.enumerated() {
            if index >= limit, let (finished, output) = await group.next() {
                results[finished] = output
            }
            group.addTask { (index, await transform(item)) }
        }
        for await (finished, output) in group {
            results[finished] = output
        }
        return results.compactMap { $0 }
    }
}
