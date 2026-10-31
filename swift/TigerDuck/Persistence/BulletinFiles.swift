import Foundation

/// The bulletin list and the bulletins opened, as the backend served them to the account.
final class BulletinFiles: AccountScoped {
    static let shared = BulletinFiles()

    private let folders: CacheFolders

    init(folders: CacheFolders = .app) {
        self.folders = folders
    }

    static func forgetAccount(in storage: AccountStorage) {
        storage.folders.cacheFiles.remove("bulletin_summaries.json")
        try? FileManager.default.removeItem(at: storage.folders.cache.appendingPathComponent("bulletin_details", isDirectory: true))
    }

    func saveBulletinSummaries(_ summaries: [BulletinAPI.BulletinSummary]) {
        folders.cacheFiles.save(summaries, to: "bulletin_summaries.json")
    }

    func loadBulletinSummaries() -> [BulletinAPI.BulletinSummary] {
        folders.cacheFiles.load("bulletin_summaries.json") ?? []
    }

    func saveBulletinDetail(_ detail: BulletinAPI.BulletinDetail) {
        let dir = detailsFolder
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        JSONFiles(directory: dir).save(detail, to: "\(detail.id).json")
    }

    func loadBulletinDetail(id: Int) -> BulletinAPI.BulletinDetail? {
        JSONFiles(directory: detailsFolder).load("\(id).json")
    }

    func clearBulletinDetails() {
        try? FileManager.default.removeItem(at: detailsFolder)
    }

    private var detailsFolder: URL {
        folders.cache.appendingPathComponent("bulletin_details", isDirectory: true)
    }
}
