import Defaults
import Foundation
import Observation
import os

@MainActor
@Observable
final class BulletinFeed {
    typealias Summary = BulletinAPI.BulletinSummary
    typealias Page = BulletinAPI.BulletinListResponse

    private(set) var items: [Summary] = []
    private(set) var nextCursor: Int?
    private(set) var hasMore = true
    @ObservationIgnored private let fetchPage: (_ cursor: Int?, _ includeDeleted: Bool) async throws -> Page
    @ObservationIgnored private let fetchDetail: (_ id: Int) async throws -> BulletinAPI.BulletinDetail
    @ObservationIgnored private var itemsSignIn: SignIn
    private static let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Bulletin.VM")

    convenience init(apiClient: BulletinAPIClient? = nil, for signIn: SignIn) {
        let apiClient = apiClient ?? BulletinAPIClient()
        self.init(
            page: { try await apiClient.listBulletins(limit: 30, cursor: $0, includeDeleted: $1) },
            detail: { try await apiClient.getBulletin(id: $0) },
            for: signIn
        )
    }

    init(
        page: @escaping (_ cursor: Int?, _ includeDeleted: Bool) async throws -> Page,
        detail: @escaping (_ id: Int) async throws -> BulletinAPI.BulletinDetail,
        for signIn: SignIn
    ) {
        fetchPage = page
        fetchDetail = detail
        itemsSignIn = signIn
        let cached = BulletinFiles.shared.loadBulletinSummaries()
        if !cached.isEmpty { items = Self.sortedUnique(cached) }
    }

    private struct ListSession {
        let items: [Summary]
        let nextCursor: Int?
        let hasMore: Bool
        let showDeleted: Bool
    }

    private static var listSession: ListSession?

    static func forgetListSession() {
        listSession = nil
        Defaults.reset(.bulletinsSyncedAt)
    }

    func noteSynced(for signIn: SignIn) {
        Defaults[.bulletinsSyncedAt, for: signIn] = Date()
    }

    static func forgetPreviousEndpointBulletins() {
        BulletinFiles.shared.saveBulletinSummaries([])
        BulletinFiles.shared.clearBulletinDetails()
        forgetListSession()
    }

    func page(after cursor: Int?, includeDeleted: Bool) async throws -> Page {
        try await fetchPage(cursor, includeDeleted)
    }

    func resumeSession(showDeleted: Bool) -> Bool {
        guard let session = Self.listSession, session.showDeleted == showDeleted else { return false }
        items = Self.merge(existing: items, incoming: session.items)
        nextCursor = session.nextCursor
        hasMore = session.hasMore
        return true
    }

    func add(_ page: Page, movesCursor: Bool = true) {
        items = Self.merge(existing: items, incoming: page.items)
        guard movesCursor else { return }
        nextCursor = page.nextCursor
        hasMore = page.nextCursor != nil
    }

    func add(_ summary: Summary) {
        items = Self.merge(existing: items, incoming: [summary])
    }

    func restartWalk() { nextCursor = nil }

    func endWalk() { hasMore = false }

    /// The row for `id` from the list, the copy on disk or, `fetched`, the backend; nil for a
    /// deleted bulletin.
    func summary(forId id: Int) async throws -> (summary: Summary, fetched: Bool)? {
        if let existing = items.first(where: { $0.id == id }) {
            guard !existing.isDeleted else {
                Self.logger.info("summary(forId:) skipped in-memory deleted bulletin id=\(id, privacy: .public)")
                return nil
            }
            return (existing, false)
        }
        if let hit = cachedSummary(id: id) {
            guard !hit.isDeleted else {
                Self.logger.info("summary(forId:) skipped cached deleted bulletin id=\(id, privacy: .public)")
                return nil
            }
            return (hit, false)
        }
        let detail: BulletinAPI.BulletinDetail
        do {
            detail = try await fetchDetail(id)
        } catch {
            Self.logger.error("summary(forId:) fetch failed id=\(id, privacy: .public) error=\(error.localizedDescription, privacy: .private)")
            throw error
        }
        guard !detail.isDeleted else {
            Self.logger.info("summary(forId:) skipped deleted bulletin id=\(id, privacy: .public)")
            return nil
        }
        return (Self.summary(of: detail), true)
    }

    static func keep(_ details: [BulletinAPI.BulletinDetail], files: BulletinFiles = .shared, for signIn: SignIn) {
        guard signIn.isCurrent else { return }
        files.saveBulletinSummaries(sortedUnique(details.map(summary(of:))))
        details.forEach(files.saveBulletinDetail)
    }

    private static func summary(of detail: BulletinAPI.BulletinDetail) -> Summary {
        Summary(
            id: detail.id, externalId: detail.externalId, title: detail.title, titleClean: detail.titleClean,
            canonicalOrg: detail.canonicalOrg, contentTags: detail.contentTags, importance: detail.importance,
            summary: detail.summary, sourceUrl: detail.sourceUrl, postedAt: detail.postedAt, isDeleted: detail.isDeleted
        )
    }

    private func cachedSummary(id: Int) -> Summary? {
        BulletinFiles.shared.loadBulletinSummaries().first { $0.id == id }
    }

    func persist(showDeleted: Bool, for signIn: SignIn) {
        guard signIn.isCurrent else { return }
        BulletinFiles.shared.saveBulletinSummaries(items)
        Self.listSession = ListSession(items: items, nextCursor: nextCursor, hasMore: hasMore, showDeleted: showDeleted)
    }

    var isFromBeforeSignOut: Bool { !itemsSignIn.isCurrent }

    func restartAfterSignOut(for signIn: SignIn) {
        items = Self.sortedUnique(BulletinFiles.shared.loadBulletinSummaries())
        nextCursor = nil
        hasMore = true
        itemsSignIn = signIn
    }

    private static func merge(existing: [Summary], incoming: [Summary]) -> [Summary] {
        var byId: [Int: Summary] = [:]
        for row in existing { byId[row.id] = row }
        for row in incoming { byId[row.id] = row }
        return sortedUnique(Array(byId.values))
    }

    private static func sortedUnique(_ rows: [Summary]) -> [Summary] {
        let distantPast = Date.distantPast
        return rows.sorted { lhs, rhs in
            let ld = lhs.postedAt ?? distantPast
            let rd = rhs.postedAt ?? distantPast
            if ld != rd { return ld > rd }
            return lhs.id > rhs.id
        }
    }
}

enum BulletinDetails {
    private static let apiClient = BulletinAPIClient()

    static func cached(id: Int) -> BulletinAPI.BulletinDetail? {
        BulletinFiles.shared.loadBulletinDetail(id: id)
    }

    static func fetch(id: Int, for signIn: SignIn) async throws -> BulletinAPI.BulletinDetail {
        let fresh = try await apiClient.getBulletin(id: id)
        if signIn.isCurrent { BulletinFiles.shared.saveBulletinDetail(fresh) }
        return fresh
    }
}
