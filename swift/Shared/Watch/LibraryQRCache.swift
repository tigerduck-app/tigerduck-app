import Foundation

/// The last library QR payload fetched in this process, kept so leaving the
/// library page and coming back inside the code's lifetime shows the same
/// code instead of asking the server for another one. Also what the phone
/// answers a watch request from when the code is still fresh enough.
@MainActor
public final class LibraryQRCache {
    public static let shared = LibraryQRCache()

    /// How long the library accepts a code after it was issued.
    public static let lifetime = 30
    /// A cached code with at least this many seconds left is shown again.
    public static let reuseThreshold = 15

    public private(set) var payload: String?
    public private(set) var fetchedAt: Date?

    public init() {}

    /// `remaining` is for codes handed over by the other device, which
    /// have already been counting down there.
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

    /// The cached payload while it still has `reuseThreshold` seconds left.
    public func reusable(now: Date = Date()) -> String? {
        remaining(now: now) >= Self.reuseThreshold ? payload : nil
    }
}
