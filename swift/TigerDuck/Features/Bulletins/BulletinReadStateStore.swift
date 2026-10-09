import Defaults
import Foundation
import Observation

/// @Observable cache for the local "read" state of bulletins.
///
/// Backed by `Defaults[.bulletinReadIds]`, so the set survives relaunches without an extra
/// SwiftData container. Local-only: the server never sees per-device read state, which saves a
/// round-trip and leaves no privacy footprint. `isRead` runs for every visible card on every list
/// refresh, so reads hit an in-memory `Set<Int>` mirror and UserDefaults is touched only on
/// mutation.
@MainActor
@Observable
final class BulletinReadStateStore {
    /// Hard cap so a user that never lets the prune path run can't grow
    /// the persisted Set without bound. Bulletin IDs are monotonic so
    /// dropping the lowest is dropping the oldest — and 1000 covers
    /// well beyond a year of read history.
    private static let maxRetainedIds = 1000

    private(set) var read: Set<Int>

    init() {
        self.read = Self.capped(Defaults[.bulletinReadIds])
    }

    private static func capped(_ ids: Set<Int>) -> Set<Int> {
        guard ids.count > maxRetainedIds else { return ids }
        return Set(ids.sorted(by: >).prefix(maxRetainedIds))
    }

    func isRead(_ id: Int) -> Bool {
        read.contains(id)
    }

    /// Idempotent — re-marking an already-read row is a no-op so callers
    /// can fire this from `.task` on the detail view without guarding.
    func markRead(_ id: Int) {
        guard !read.contains(id) else { return }
        read.insert(id)
        read = Self.capped(read)
        Defaults[.bulletinReadIds] = read
    }

    func markUnread(_ id: Int) {
        guard read.contains(id) else { return }
        read.remove(id)
        Defaults[.bulletinReadIds] = read
    }

    /// Convenience for swipe actions — flips state in one call.
    func toggleRead(_ id: Int) {
        if read.contains(id) {
            markUnread(id)
        } else {
            markRead(id)
        }
    }

    /// Mark every supplied id as read in one atomic Defaults write. Used
    /// by the list page's "Mark all as read" action so a stack of unreads
    /// can be cleared without paging through. Ids already in the set are
    /// harmlessly included in the union.
    func markAllRead(_ ids: some Sequence<Int>) {
        let incoming = Set(ids)
        let merged = Self.capped(read.union(incoming))
        guard merged != read else { return }
        read = merged
        Defaults[.bulletinReadIds] = merged
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
