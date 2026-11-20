import Foundation

/// The club directory and activity feed as clubs.ntust.edu.tw last answered. Both are public, so a
/// sign-out keeps them.
nonisolated struct ClubFiles: Sendable {
    nonisolated struct StoredDirectory: Codable, Equatable, Sendable {
        let body: Data
        let storedAt: Date
        /// How long the answer stays fresh, from its `Cache-Control`.
        let maxAge: TimeInterval
    }

    private static let directoryFile = "club_directory.json"
    private static let activitiesFile = "club_activities.json"

    let folders: CacheFolders

    init(folders: CacheFolders = .app) {
        self.folders = folders
    }

    func loadDirectory() -> StoredDirectory? {
        folders.cacheFiles.load(Self.directoryFile)
    }

    func saveDirectory(_ directory: StoredDirectory) {
        folders.cacheFiles.save(directory, to: Self.directoryFile)
    }

    func loadActivities() -> ETaggedBody? {
        folders.cacheFiles.load(Self.activitiesFile)
    }

    func saveActivities(_ activities: ETaggedBody) {
        folders.cacheFiles.save(activities, to: Self.activitiesFile)
    }
}
