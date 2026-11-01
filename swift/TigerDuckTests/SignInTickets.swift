@testable import TigerDuck

extension AccountSession.Ticket {
    static func after(signOuts: Int) -> Self {
        var signIns = SignInCount()
        for _ in 0..<signOuts { signIns.moveOn() }
        return signIns.ticket
    }
}
