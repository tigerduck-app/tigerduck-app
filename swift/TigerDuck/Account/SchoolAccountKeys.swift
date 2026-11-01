import Defaults
import Foundation

enum SchoolAccountKeys: AccountScoped {
    static func forgetAccount(in storage: AccountStorage) {
        Defaults[.schoolDataSyncedAt] = nil
        Defaults[.classTableSelectedSemester] = nil
        Defaults[.emptyClassroomBuilding] = nil
        SyncProgress.forget()
    }

    static func noteSchoolDataSynced(for signIn: SignIn) {
        guard signIn.isCurrent else { return }
        Defaults[.schoolDataSyncedAt] = Date()
    }

    static func pickSemester(_ semester: String, for signIn: SignIn) {
        guard signIn.isCurrent else { return }
        Defaults[.classTableSelectedSemester] = semester
    }

    static func pickEmptyClassroomBuilding(_ building: String?, for signIn: SignIn) {
        guard signIn.isCurrent else { return }
        Defaults[.emptyClassroomBuilding] = building
    }
}
