import Defaults
import Foundation

enum SchoolAccountKeys: AccountScoped {
    static func forgetAccount(in storage: AccountStorage) {
        Defaults[.schoolDataSyncedAt] = nil
        Defaults[.demoAccountSignedIn] = false
        Defaults[.classTableSelectedSemester] = nil
        Defaults[.emptyClassroomBuilding] = nil
        SyncProgress.forget()
    }

    static func noteSchoolDataSynced(for signIn: SignIn) {
        guard signIn.isCurrent else { return }
        Defaults[.schoolDataSyncedAt] = Date()
    }

    /// Read at launch, before any request, to sign the store-review account in again.
    static func noteDemoSignedIn(for signIn: SignIn) {
        guard signIn.isCurrent, signIn.isDemo else { return }
        Defaults[.demoAccountSignedIn] = true
    }

    static var demoIsSignedIn: Bool { Defaults[.demoAccountSignedIn] }

    static func pickSemester(_ semester: String, for signIn: SignIn) {
        guard signIn.isCurrent else { return }
        Defaults[.classTableSelectedSemester] = semester
    }

    static func pickEmptyClassroomBuilding(_ building: String?, for signIn: SignIn) {
        guard signIn.isCurrent else { return }
        Defaults[.emptyClassroomBuilding] = building
    }
}
