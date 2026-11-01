import Foundation

nonisolated struct RefreshTokenUseBudget: Equatable, Sendable {
    static let limit = 2
    static let spent = RefreshTokenUseBudget(uses: limit)

    let uses: Int

    init(uses: Int = 0) {
        self.uses = uses
    }

    init(stored: String?) {
        self.init(uses: stored.flatMap(Int.init) ?? 0)
    }

    var allowsSend: Bool { uses < Self.limit }

    var stored: String { String(uses) }

    func afterSend(mayHaveUsed: Bool) -> RefreshTokenUseBudget {
        mayHaveUsed ? RefreshTokenUseBudget(uses: uses + 1) : self
    }
}
