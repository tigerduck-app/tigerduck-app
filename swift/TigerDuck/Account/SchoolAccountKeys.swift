import Defaults
import Foundation

enum SchoolAccountKeys: AccountScoped {
    static func forgetAccount(in storage: AccountStorage) {
        Defaults.reset(.schoolDataSyncedAt, .classTableSelectedSemester, .emptyClassroomBuilding)
        SyncProgress.forget()
    }

    static func noteSchoolDataSynced(for signIn: SignIn) {
        Defaults[.schoolDataSyncedAt, for: signIn] = Date()
    }

    static func pickSemester(_ semester: String, for signIn: SignIn) {
        Defaults[.classTableSelectedSemester, for: signIn] = semester
    }

    static func pickEmptyClassroomBuilding(_ building: String?, for signIn: SignIn) {
        Defaults[.emptyClassroomBuilding, for: signIn] = building
    }
}
