import Foundation

/// Edits this device made that a pull must not undo before they land: marks and course ignores on
/// their way into the outbox, course hides of the last two minutes and terms being reset.
@MainActor
final class LocalEdits {
    static let courseDeleteGraceInterval: TimeInterval = 120

    private let account: AccountSession
    /// Marks and course ignores not in the outbox yet, by assignment id or course key.
    var pendingOverrides: Set<String> = []
    /// Moves with every mark and course ignore edit, so a full sync tells one made while it read.
    var overrideEditGeneration = 0
    var resettingSemesters: Set<String> = []
    private var courseDeletions = SignInScoped<[String: Date]>(empty: [:])

    init(account: AccountSession) {
        self.account = account
    }

    var recentCourseDeletions: [String: Date] {
        get { courseDeletions.value(in: account) }
        set { courseDeletions.set(newValue, in: account) }
    }
}
