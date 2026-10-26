import Foundation

/// What the Storage page lists, in page order.
nonisolated enum StorageKind: CaseIterable, Hashable, Sendable {
    case moodleFiles
    case mail
    case websiteData

    /// Mail has to download again and sites may sign the user out, so those two ask first.
    var confirmsDelete: Bool { self != .moodleFiles }
}

/// Bytes per kind; a kind that could not be measured has none.
nonisolated struct StorageSizes: Equatable, Sendable {
    struct Segment: Equatable, Sendable {
        let kind: StorageKind
        let share: Double
    }

    var bytes: [StorageKind: Int] = [:]

    var total: Int { bytes.values.reduce(0, +) }

    static func text(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// The bar's parts: every kind above 0, in page order, as its share of the total.
    var segments: [Segment] {
        let total = total
        guard total > 0 else { return [] }
        return StorageKind.allCases.compactMap { kind in
            guard let size = bytes[kind], size > 0 else { return nil }
            return Segment(kind: kind, share: Double(size) / Double(total))
        }
    }
}

/// Measures every kind and clears one, each through the store given for it.
nonisolated struct StorageCleaner: Sendable {
    struct Store: Sendable {
        let measure: @Sendable () async -> Int?
        let clear: @Sendable () async -> Void
    }

    let stores: [StorageKind: Store]

    func measure() async -> StorageSizes {
        var sizes = StorageSizes()
        for (kind, store) in stores {
            sizes.bytes[kind] = await store.measure()
        }
        return sizes
    }

    func delete(_ kind: StorageKind) async -> StorageSizes {
        await stores[kind]?.clear()
        return await measure()
    }
}
