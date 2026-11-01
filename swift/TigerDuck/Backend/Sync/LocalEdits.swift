import Foundation

@MainActor
final class LocalEdits {
    static let courseDeleteGraceInterval: TimeInterval = 120

    var pendingOverrides: Set<String> = []
    var overrideEditGeneration = 0
    var resettingSemesters: Set<String> = []
    private var courseDeletions = SignInBound<[String: Date]>(empty: [:])

    var recentCourseDeletions: [String: Date] { courseDeletions.value }

    func setRecentCourseDeletions(_ deletions: [String: Date], for signIn: SignIn) {
        courseDeletions.set(deletions, for: signIn)
    }
}
