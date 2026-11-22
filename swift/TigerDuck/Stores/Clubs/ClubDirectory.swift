import Defaults
import Foundation

/// The clubs of clubs.ntust.edu.tw, as the subscribe screen lists and searches them. The stored
/// answer is fetched again only once it is older than the `max-age` it came with.
@MainActor
@Observable
final class ClubDirectory {
    typealias Club = ClubCard

    static let shared = ClubDirectory()

    /// The order of the list's groups; a club of another attribute, or of none, comes after them.
    nonisolated static let attributeOrder = ["學藝性", "藝術性", "體育性", "聯誼性", "服務性", "自治性"]

    /// Every club, by attribute and then by name.
    private(set) var clubs: [ClubCard] = []
    /// Why the last fetch failed; nil once one succeeds.
    private(set) var failure: (any Error)?
    /// Whether the last fetch failed in the club system's nightly maintenance (`ClubAPIClient.isMaintenance`).
    private(set) var isUnderMaintenance = false
    @ObservationIgnored private let files: ClubFiles
    @ObservationIgnored private let client: ClubAPIClient
    @ObservationIgnored private let chinese: () -> Bool
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var stored: (at: Date, freshness: FreshnessPolicy)?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var demoGeneration = 0

    init(
        files: ClubFiles = ClubFiles(),
        client: ClubAPIClient = ClubAPIClient(),
        chinese: @escaping () -> Bool = { !LanguageManager.isCurrentLanguageNonChinese(appLanguage: Defaults[.appLanguage]) },
        now: @escaping () -> Date = { Date() }
    ) {
        self.files = files
        self.client = client
        self.chinese = chinese
        self.now = now
        showStored()
    }

    func showStored() {
        failure = nil
        isUnderMaintenance = false
        guard let file = files.loadDirectory(), let read = try? ClubAPIList<ClubCard>.decode(file.body) else {
            stored = nil
            if !clubs.isEmpty { clubs = [] }
            return
        }
        take(read, storedAt: file.storedAt, maxAge: file.maxAge)
    }

    /// The demo account's directory, which no server sends. It counts as fresh for the longest
    /// `max-age`, so no refresh asks for another, and leaves the stored answer on disk. A fetch
    /// already under way keeps nothing.
    func show(_ clubs: [ClubCard]) {
        demoGeneration += 1
        take(clubs, storedAt: now(), maxAge: ClubAPIClient.longestMaxAge)
        failure = nil
        isUnderMaintenance = false
    }

    func club(_ id: Int) -> ClubCard? {
        clubs.first { $0.id == id }
    }

    func displayName(of club: ClubCard) -> String {
        club.displayName(chinese: chinese())
    }

    /// The clubs whose Chinese or English name holds every word of `query`, in list order.
    func search(_ query: String) -> [ClubCard] {
        Self.matching(query, in: clubs)
    }

    /// Fetches the directory once the stored answer is older than its `max-age`; a call during a
    /// fetch waits for it. A failed fetch keeps the stored answer.
    func refresh() async {
        if let refreshTask { return await refreshTask.value }
        if let stored, stored.freshness.isFresh(storedAt: stored.at, now: now()) { return }
        let task = Task { await fetch() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func fetch() async {
        let generation = demoGeneration
        do {
            let answer = try await client.clubs()
            guard generation == demoGeneration else { return }
            let read = try ClubAPIList<ClubCard>.decode(answer.body)
            let storedAt = now()
            files.saveDirectory(ClubFiles.StoredDirectory(body: answer.body, storedAt: storedAt, maxAge: answer.maxAge))
            take(read, storedAt: storedAt, maxAge: answer.maxAge)
            failure = nil
            isUnderMaintenance = false
        } catch {
            if !AppLogger.isCancellation(error), generation == demoGeneration {
                failure = error
                isUnderMaintenance = ClubAPIClient.isMaintenance(error, at: now())
            }
            if ClubAPIClient.isWorthReporting(error) {
                AppLogger.captureError(error, context: ["service": "clubDirectoryRefresh"])
            }
        }
    }

    private func take(_ read: [ClubCard], storedAt: Date, maxAge: TimeInterval) {
        stored = (storedAt, FreshnessPolicy(lifetime: maxAge))
        let listed = Self.listed(read, chinese: chinese())
        if listed != clubs { clubs = listed }
    }

    nonisolated static func listed(_ clubs: [ClubCard], chinese: Bool) -> [ClubCard] {
        func group(_ club: ClubCard) -> Int {
            club.attribute.flatMap { attributeOrder.firstIndex(of: $0) } ?? attributeOrder.count
        }
        return clubs.sorted { lhs, rhs in
            if group(lhs) != group(rhs) { return group(lhs) < group(rhs) }
            let order = lhs.displayName(chinese: chinese).localizedStandardCompare(rhs.displayName(chinese: chinese))
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }

    nonisolated static func matching(_ query: String, in clubs: [ClubCard]) -> [ClubCard] {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return clubs }
        return clubs.filter { club in
            let names = [club.name, club.enName].compactMap { $0 }
            return words.allSatisfy { word in names.contains { $0.containsSearchWord(word) } }
        }
    }
}
