import Defaults

enum SchoolAccountKeys: AccountScoped {
    static func forgetAccount(in storage: AccountStorage) {
        Defaults[.schoolDataSyncedAt] = nil
        Defaults[.classTableSelectedSemester] = nil
        Defaults[.emptyClassroomBuilding] = nil
        SignOutCheck.forgetSyncProgress()
    }
}
