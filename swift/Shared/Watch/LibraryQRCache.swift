import Foundation

@MainActor
public final class LibraryQRCache {
    public static let shared = LibraryQRCache()

    nonisolated public static let lifetime = 30
    nonisolated public static let reuseThreshold = 15

    public private(set) var payload: String?
    public private(set) var fetchedAt: Date?

    public init() {}

    public func store(_ payload: String, remaining: Int = LibraryQRCache.lifetime, now: Date = Date()) {
        self.payload = payload
        fetchedAt = now.addingTimeInterval(TimeInterval(remaining - Self.lifetime))
    }

    public func clear() {
        payload = nil
        fetchedAt = nil
    }

    public func remaining(now: Date = Date()) -> Int {
        guard payload != nil, let fetchedAt else { return 0 }
        return max(0, Self.lifetime - Int(now.timeIntervalSince(fetchedAt)))
    }

    public func reusable(now: Date = Date()) -> String? {
        remaining(now: now) >= Self.reuseThreshold ? payload : nil
    }
}
