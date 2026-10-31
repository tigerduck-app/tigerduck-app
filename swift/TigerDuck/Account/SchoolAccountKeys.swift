import Defaults

/// Keys of the school account that no store of their own holds.
enum SchoolAccountKeys: AccountScoped {
    static func forgetAccount(in storage: AccountStorage) {
        Defaults[.schoolDataSyncedAt] = nil
        Defaults[.classTableSelectedSemester] = nil
        Defaults[.emptyClassroomBuilding] = nil
        AppState.forgetSyncProgress()
    }
}
