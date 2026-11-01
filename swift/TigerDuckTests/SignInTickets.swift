@testable import TigerDuck

/// A sign-in no test ends, for writes and sends that are meant to land.
let testSignIn = SignInSeries().currentSignIn

/// A sign-in that ended before the test began.
let endedTestSignIn = TestSignIn.ended().signIn

/// A sign-in a test ends from any actor, as its account signing out.
final class TestSignIn: Sendable {
    private let series = SignInSeries()
    let signIn: SignIn

    init() {
        signIn = series.currentSignIn
    }

    static func ended() -> TestSignIn {
        let ended = TestSignIn()
        ended.signOut()
        return ended
    }

    func signOut() { series.end() }
}
