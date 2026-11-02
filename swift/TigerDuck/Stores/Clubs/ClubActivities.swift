import Foundation
import TigerDuckCore

/// An activity of a subscribed club on one Taipei day, with what the class table draws and shows.
nonisolated struct ClubOccurrence: Identifiable, Equatable, Sendable {
    /// The activity's id.
    let id: Int
    let clubID: Int
    /// The club's name in the interface's language.
    let clubName: String
    /// `0xRRGGBB`.
    let color: UInt32
    /// The club's place in the user's order, 0 first; where two clubs overlap, the lower one shows.
    let priority: Int
    /// `yyyy-MM-dd`.
    let day: String
    /// Minutes after midnight, Taipei time.
    let start: Int
    let end: Int
    let location: String
    let kind: ClubActivityKind
    let name: String
    let content: String
}

/// The school-wide club activity feed as last fetched, which the class table refreshes with its
/// own data and filters to the subscribed clubs.
@MainActor
@Observable
final class ClubActivities {
    static let shared = ClubActivities()

    private(set) var activities: [ClubActivity] = []
    @ObservationIgnored private let files: ClubFiles
    @ObservationIgnored private let client: ClubAPIClient
    @ObservationIgnored private let subscriptions: ClubSubscriptions
    @ObservationIgnored private let directory: ClubDirectory
    @ObservationIgnored private var etag: String?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(
        files: ClubFiles = ClubFiles(),
        client: ClubAPIClient = ClubAPIClient(),
        subscriptions: ClubSubscriptions = .shared,
        directory: ClubDirectory = .shared
    ) {
        self.files = files
        self.client = client
        self.subscriptions = subscriptions
        self.directory = directory
        if let stored = files.loadActivities(), let read = try? ClubAPIList<ClubActivity>.decode(stored.body) {
            activities = read
            etag = stored.etag
        }
    }

    /// Asks whether the feed changed since the stored copy; a call during a fetch waits for it. A
    /// failed fetch keeps the stored copy.
    func refresh() async {
        if let refreshTask { return await refreshTask.value }
        let task = Task { await fetch() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func fetch() async {
        do {
            guard let copy = try await client.activities(etag: etag) else { return }
            let read = try ClubAPIList<ClubActivity>.decode(copy.body)
            files.saveActivities(copy)
            etag = copy.etag
            if read != activities { activities = read }
        } catch {
            if ClubAPIClient.isWorthReporting(error) {
                AppLogger.captureError(error, context: ["service": "clubActivitiesRefresh"])
            }
        }
    }

    /// The activities of subscribed clubs on `days`, by day, start and priority. Only an activity
    /// that starts and ends on one day with both times has a place (`ClubActivity.oneDay`).
    func occurrences(on days: [Date]) -> [ClubOccurrence] {
        Self.occurrences(
            of: activities,
            on: Set(days.map(TaipeiTime.dayKey(for:))),
            clubs: subscriptions.subscribedIDs.map { ($0, subscriptions.color(of: $0)) },
            names: Dictionary(directory.clubs.map { ($0.id, directory.displayName(of: $0)) }, uniquingKeysWith: { first, _ in first })
        )
    }

    /// `clubs` are the subscribed clubs, highest priority first; a club `names` lacks keeps the
    /// feed's Chinese name.
    nonisolated static func occurrences(
        of activities: [ClubActivity], on days: Set<String>, clubs: [(id: Int, color: UInt32)], names: [Int: String]
    ) -> [ClubOccurrence] {
        let priority = Dictionary(clubs.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        return activities.compactMap { activity -> ClubOccurrence? in
            guard let rank = priority[activity.clubID], let placed = activity.oneDay, days.contains(placed.day) else { return nil }
            return ClubOccurrence(
                id: activity.id, clubID: activity.clubID, clubName: names[activity.clubID] ?? activity.clubName,
                color: clubs[rank].color, priority: rank, day: placed.day, start: placed.start, end: placed.end,
                location: activity.location, kind: activity.kind, name: activity.name, content: activity.content
            )
        }
        .sorted { ($0.day, $0.start, $0.priority, $0.id) < ($1.day, $1.start, $1.priority, $1.id) }
    }
}
