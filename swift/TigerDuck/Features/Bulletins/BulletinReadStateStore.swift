import Defaults
import Foundation
import Observation

@MainActor
@Observable
final class BulletinReadStateStore {
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

    func toggleRead(_ id: Int) {
        if read.contains(id) {
            markUnread(id)
        } else {
            markRead(id)
        }
    }

    func markAllRead(_ ids: some Sequence<Int>) {
        let incoming = Set(ids)
        let merged = Self.capped(read.union(incoming))
        guard merged != read else { return }
        read = merged
        Defaults[.bulletinReadIds] = merged
    }

    func prune(keepingIdsIn ids: some Sequence<Int>) {
        let alive = Set(ids)
        let trimmed = read.intersection(alive)
        guard trimmed.count != read.count else { return }
        read = trimmed
        Defaults[.bulletinReadIds] = trimmed
    }
}
