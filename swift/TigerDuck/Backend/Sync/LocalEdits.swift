import Foundation

@MainActor
final class LocalEdits {
    static let courseDeleteGraceInterval: TimeInterval = 120

    private let account: AccountSession
    var pendingOverrides: Set<String> = []
    var overrideEditGeneration = 0
    var resettingSemesters: Set<String> = []
    private var courseDeletions = SignInBound<[String: Date]>(empty: [:])

    init(account: AccountSession) {
        self.account = account
    }

    var recentCourseDeletions: [String: Date] {
        get { courseDeletions.value }
        set { courseDeletions.set(newValue, for: account.currentSignIn) }
    }
}
