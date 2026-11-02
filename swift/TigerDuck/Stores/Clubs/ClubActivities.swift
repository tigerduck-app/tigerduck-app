import Foundation

/// The school-wide club activity feed as last fetched, which the class table refreshes with its
/// own data and filters to the subscribed clubs.
@MainActor
@Observable
final class ClubActivities {
    static let shared = ClubActivities()

    private(set) var activities: [ClubActivity] = []
    @ObservationIgnored private let files: ClubFiles
    @ObservationIgnored private let client: ClubAPIClient
    @ObservationIgnored private var etag: String?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(files: ClubFiles = ClubFiles(), client: ClubAPIClient = ClubAPIClient()) {
        self.files = files
        self.client = client
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
            if !AppLogger.isCancellation(error) {
                AppLogger.captureError(error, context: ["service": "clubActivitiesRefresh"])
            }
        }
    }
}
