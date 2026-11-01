import Foundation
@testable import TigerDuck

@MainActor
struct TestCache {
    let folders: CacheFolders
    let courses: CourseStore
    let assignments: AssignmentStore
    let colors: CourseColorFiles
    let bulletins: BulletinFiles
    let scores: ScoreReportFiles
    let moodle: MoodleFiles
    let catalog: CourseCatalogFiles

    init(cacheDir: URL, persistentDir: URL) {
        self.init(folders: CacheFolders(cache: cacheDir, persistent: persistentDir))
    }

    init(folders: CacheFolders) {
        self.folders = folders
        courses = CourseStore(folders: folders)
        assignments = AssignmentStore(folders: folders)
        colors = CourseColorFiles(folders: folders)
        bulletins = BulletinFiles(folders: folders)
        scores = ScoreReportFiles(folders: folders)
        moodle = MoodleFiles(folders: folders)
        catalog = CourseCatalogFiles(folders: folders)
    }

    var persistentDir: URL { folders.persistent }

    func forgetAccount() {
        for store in SignOutPlan.schoolStores {
            store.forgetAccount(in: AccountStorage(folders: folders))
        }
    }
    var moodleFilesDir: URL { moodle.moodleFilesDir }
}

extension CacheFolders {
    init(root: URL) {
        self.init(cache: root.appending(path: "cache/"), persistent: root.appending(path: "persistent/"))
    }
}
