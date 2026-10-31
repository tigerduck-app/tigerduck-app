import Foundation

/// How many times the backend may have used a refresh token without this device keeping the pair
/// it answered: sends that may have reached it and got no reply, a server error or a 200 the
/// device could not keep. The backend rotates a token sent again while its successor is unused,
/// so a token goes out at most `limit` times; after that the app signs in again. A new pair starts
/// over. Kept with the tokens, as the app can end before the next refresh signs in again.
nonisolated struct RefreshTokenUseBudget: Equatable, Sendable {
    static let limit = 2
    static let spent = RefreshTokenUseBudget(uses: limit)

    let uses: Int

    init(uses: Int = 0) {
        self.uses = uses
    }

    /// Reads the count stored with the tokens; a missing one is a fresh pair's.
    init(stored: String?) {
        self.init(uses: stored.flatMap(Int.init) ?? 0)
    }

    var allowsSend: Bool { uses < Self.limit }

    var stored: String { String(uses) }

    func afterSend(mayHaveUsed: Bool) -> RefreshTokenUseBudget {
        mayHaveUsed ? RefreshTokenUseBudget(uses: uses + 1) : self
    }
}
