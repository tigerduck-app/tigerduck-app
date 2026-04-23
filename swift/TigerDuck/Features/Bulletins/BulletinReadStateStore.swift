import Defaults
import Foundation
import Observation

/// @Observable cache for the local "已讀" state of bulletins.
///
/// Backed by `Defaults[.bulletinReadIds]` so the set survives app
/// re-launches without an extra SwiftData container. Local-only — the
/// server never sees per-device read state, matching the user's MVP
/// preference (no extra round-trip, no privacy footprint).
///
/// The hot read path (`isRead`) needs to be cheap because it fires for
/// every visible card on every list refresh, so we keep an in-memory
/// `Set<Int>` mirror and only touch UserDefaults on mutation.
@MainActor
@Observable
final class BulletinReadStateStore {
    private(set) var read: Set<Int>

    init() {
        self.read = Defaults[.bulletinReadIds]
    }

    func isRead(_ id: Int) -> Bool {
        read.contains(id)
    }

    /// Idempotent — re-marking an already-read row is a no-op so callers
    /// can fire this from `.task` on the detail view without guarding.
    func markRead(_ id: Int) {
        guard !read.contains(id) else { return }
        read.insert(id)
        Defaults[.bulletinReadIds] = read
    }

    /// Drop ids that are no longer present in the supplied list. Lets the
    /// retention path keep `bulletinReadIds` from growing unbounded as
    /// older bulletins fall off the server side.
    func prune(keepingIdsIn ids: some Sequence<Int>) {
        let alive = Set(ids)
        let trimmed = read.intersection(alive)
        guard trimmed.count != read.count else { return }
        read = trimmed
        Defaults[.bulletinReadIds] = trimmed
    }
}
