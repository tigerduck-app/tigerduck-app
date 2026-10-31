@testable import TigerDuck

extension AccountSession.Ticket {
    /// The ticket after `signOuts` sign-outs; tickets after as many sign-outs are equal.
    static func after(signOuts: Int) -> Self {
        var signIns = SignInCount()
        for _ in 0..<signOuts { signIns.moveOn() }
        return signIns.ticket
    }
}
