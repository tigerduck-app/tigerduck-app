import Foundation

nonisolated struct UnconfirmedRefreshSends: Equatable, Sendable {
    static let maxUnconfirmedSends = 2
    static let spent = UnconfirmedRefreshSends(uses: maxUnconfirmedSends)

    let uses: Int

    init(uses: Int = 0) {
        self.uses = uses
    }

    init(stored: String?) {
        self.init(uses: stored.flatMap(Int.init) ?? 0)
    }

    var allowsSend: Bool { uses < Self.maxUnconfirmedSends }

    var stored: String { String(uses) }

    func afterSend(mayHaveUsed: Bool) -> UnconfirmedRefreshSends {
        mayHaveUsed ? UnconfirmedRefreshSends(uses: uses + 1) : self
    }
}
