import Foundation
@testable import TigerDuck

/// The sign-ins of `testSignIn`, which no test ends.
let testSignIns = SignInSeries()

/// A sign-in no test ends, for writes and sends that are meant to land.
let testSignIn = testSignIns.currentSignIn

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

extension BackendAuth {
    /// A header of the current sign-in of `signIns`, as the token manager's names the sign-in of its token.
    static func signedIn(
        in signIns: SignInSeries = testSignIns, _ header: @escaping @Sendable () async -> String?
    ) -> BackendAuth {
        BackendAuth(header: { await header().map { ($0, signIns.currentSignIn) } }, recover: { _, _, _ in false })
    }
}

extension PushAPIClient {
    convenience init(
        baseURLProvider: @escaping @Sendable () -> URL = { PushServerConfig.resolveServerURL() },
        session: URLSession? = nil,
        authHeaderProvider: @escaping @Sendable () async -> String?,
        versionGate: APIVersionGate? = nil,
        signIns: SignInSeries = testSignIns
    ) {
        self.init(baseURLProvider: baseURLProvider, session: session, auth: .signedIn(in: signIns, authHeaderProvider),
                  versionGate: versionGate)
    }
}

extension BulletinAPIClient {
    convenience init(
        baseURLProvider: @escaping @Sendable () -> URL,
        session: URLSession?,
        authHeaderProvider: @escaping @Sendable () async -> String?
    ) {
        self.init(baseURLProvider: baseURLProvider, session: session, auth: .signedIn(authHeaderProvider))
    }
}
