import Foundation
import os
import Testing
@testable import TigerDuck

/// `MoodleAutologinService` with stand-in keys, clocks and sign-outs, and its key request against
/// `SettingsAPIStub` on a site that does not exist, so no request reaches Moodle.
@MainActor
struct MoodleAutologinServiceTests {
    private static let page = URL(string: "https://moodle2.ntust.edu.tw/mod/assign/view.php?id=5501")!
    private static let autologinLink = "https://moodle2.ntust.edu.tw/admin/tool/mobile/autologin.php"
    private static let key = MoodleAutologinService.Key(userId: 42, value: "k3y", autologinURL: autologinLink)
    private static let signedInPage = URL(
        string: autologinLink + "?userid=42&key=k3y&urltogo=https%3A%2F%2Fmoodle2.ntust.edu.tw%2Fmod%2Fassign%2Fview.php%3Fid%3D5501"
    )!

    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    private actor KeyRequests {
        private(set) var count = 0
        func record() { count += 1 }
    }

    /// A service with its own sign-in generation, never the app's session generation, which
    /// any test that signs out would move under this one.
    private static func service(
        clock: OSAllocatedUnfairLock<Date> = OSAllocatedUnfairLock(initialState: start),
        signInGeneration: @escaping () -> Int = { 0 },
        keySource: @escaping @Sendable () async throws -> MoodleAutologinService.Key?
    ) -> MoodleAutologinService {
        MoodleAutologinService(
            keySource: keySource,
            now: { clock.withLock { $0 } },
            signInGeneration: signInGeneration
        )
    }

    private static func answering(
        _ key: MoodleAutologinService.Key? = key,
        _ requests: KeyRequests = KeyRequests()
    ) -> @Sendable () async throws -> MoodleAutologinService.Key? {
        {
            await requests.record()
            return key
        }
    }

    // MARK: - Link

    @Test("the sign-in link carries the account, the key and the whole page as one encoded value")
    func signedInURLEncodesThePage() throws {
        let page = try #require(URL(string: "https://moodle2.ntust.edu.tw/mod/forum/discuss.php?d=1&parent=2+3#p4"))
        let url = try #require(MoodleAutologinService.signedInURL(Self.key, opening: page))
        #expect(url.absoluteString == Self.autologinLink
            + "?userid=42&key=k3y&urltogo=https%3A%2F%2Fmoodle2.ntust.edu.tw%2Fmod%2Fforum%2Fdiscuss.php%3Fd%3D1%26parent%3D2%2B3%23p4")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        #expect(items?.map(\.name) == ["userid", "key", "urltogo"])
        #expect(items?.last?.value == page.absoluteString)
    }

    @Test("a page on the Moodle site opens through the sign-in link")
    func moodlePageIsSignedIn() async {
        let requests = KeyRequests()
        let service = Self.service(keySource: Self.answering(Self.key, requests))
        #expect(await service.url(for: Self.page) == Self.signedInPage)
        #expect(await requests.count == 1)
    }

    @Test("a link that is not an HTTPS page on the Moodle site asks for no key", arguments: [
        "http://moodle2.ntust.edu.tw/mod/assign/view.php?id=5501",
        "https://moodle2.ntust.edu.tw.example.com/mod/assign/view.php?id=5501",
        "https://www.ntust.edu.tw/",
        "moodlemobile://https://moodle2.ntust.edu.tw?redirect=/mod/assign/view.php?id%3D5501",
        "tigerduck://assignment/5501",
    ])
    func otherLinksAreLeftAlone(_ link: String) async throws {
        let url = try #require(URL(string: link))
        let requests = KeyRequests()
        let service = Self.service(keySource: Self.answering(Self.key, requests))
        #expect(await service.url(for: url) == url)
        #expect(await requests.count == 0)
    }

    @Test("a sign-in link that is not HTTPS on the Moodle site is never used", arguments: [
        "http://moodle2.ntust.edu.tw/admin/tool/mobile/autologin.php",
        "https://moodle2.ntust.edu.tw.example.com/admin/tool/mobile/autologin.php",
        "https://example.com/admin/tool/mobile/autologin.php?moodle2.ntust.edu.tw",
        "moodlemobile://https://moodle2.ntust.edu.tw",
        "",
    ])
    func foreignSignInLinkIsRefused(_ link: String) async {
        let key = MoodleAutologinService.Key(userId: 42, value: "k3y", autologinURL: link)
        #expect(MoodleAutologinService.signedInURL(key, opening: Self.page) == nil)
        #expect(await Self.service(keySource: Self.answering(key)).url(for: Self.page) == Self.page)
    }

    // MARK: - Rate limit

    @Test("within six minutes of a key a page opens as it is, without asking Moodle")
    func oneKeyPerInterval() async {
        let requests = KeyRequests()
        let clock = OSAllocatedUnfairLock(initialState: Self.start)
        let service = Self.service(clock: clock, keySource: Self.answering(Self.key, requests))

        #expect(await service.url(for: Self.page) == Self.signedInPage)
        clock.withLock { $0 += MoodleAutologinService.keyInterval - 1 }
        #expect(await service.url(for: Self.page) == Self.page)
        #expect(await requests.count == 1)

        clock.withLock { $0 += 1 }
        #expect(await service.url(for: Self.page) == Self.signedInPage)
        #expect(await requests.count == 2)

        // A clock set back leaves the last key in the future; Moodle's own clock decides.
        clock.withLock { $0 -= 3600 }
        #expect(await service.url(for: Self.page) == Self.signedInPage)
        #expect(await requests.count == 3)
    }

    @Test("a page opened while a key is on its way opens as it is, and asks for no second key")
    func keyOnItsWay() async throws {
        let requests = KeyRequests()
        let sleeper = ManualSleeper()
        let key = Self.key
        let service = Self.service {
            await requests.record()
            await sleeper.sleep(for: .zero)
            return key
        }

        let first = Task { await service.url(for: Self.page) }
        try await sleeper.waitUntilArmed()
        // The second open runs on its own task, so one parked behind the first request fails
        // the wait instead of hanging the test.
        let second = OSAllocatedUnfairLock<URL?>(initialState: nil)
        Task {
            let url = await service.url(for: Self.page)
            second.withLock { $0 = url }
        }
        try await waitUntil { second.withLock { $0 } != nil }
        await sleeper.fire()

        #expect(second.withLock { $0 } == Self.page)
        #expect(await first.value == Self.signedInPage)
        #expect(await requests.count == 1)
    }

    // MARK: - Fallbacks

    @Test("a key that arrives after a sign-out opens the page as it is and starts no wait")
    func signOutWhileKeyIsOnItsWay() async {
        let requests = KeyRequests()
        let signOuts = OSAllocatedUnfairLock(initialState: 0)
        let signsOutWhileWaiting = OSAllocatedUnfairLock(initialState: true)
        let key = Self.key
        let service = Self.service(signInGeneration: { signOuts.withLock { $0 } }) {
            await requests.record()
            if signsOutWhileWaiting.withLock({ $0 }) { signOuts.withLock { $0 += 1 } }
            return key
        }

        #expect(await service.url(for: Self.page) == Self.page)
        signsOutWhileWaiting.withLock { $0 = false }
        #expect(await service.url(for: Self.page) == Self.signedInPage)
        #expect(await requests.count == 2)
    }

    @Test("a failed request opens the page as it is and is not retried, and the next page asks again")
    func failedRequest() async {
        let requests = KeyRequests()
        let service = Self.service {
            await requests.record()
            throw MoodleWebserviceError.transientNetwork(underlying: "offline")
        }

        #expect(await service.url(for: Self.page) == Self.page)
        #expect(await requests.count == 1)
        #expect(await service.url(for: Self.page) == Self.page)
        #expect(await requests.count == 2)
    }

    @Test("no key, or an empty one, opens the page as it is and starts no wait")
    func noKey() async {
        let empty = MoodleAutologinService.Key(userId: 42, value: "", autologinURL: Self.autologinLink)
        for answer in [nil, empty] {
            let requests = KeyRequests()
            let service = Self.service(keySource: Self.answering(answer, requests))
            #expect(await service.url(for: Self.page) == Self.page)
            #expect(await service.url(for: Self.page) == Self.page)
            #expect(await requests.count == 2)
        }
    }

    // MARK: - Request

    private static let site = URL(string: "https://moodle-stub.invalid")!

    private static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        return URLSession(configuration: config)
    }

    /// The URL the key request posts to; the token keeps it unique to one test.
    private static func endpoint(token: String) -> URL {
        URL(string: "https://moodle-stub.invalid/webservice/rest/server.php"
            + "?moodlewsrestformat=json&wsfunction=tool_mobile_get_autologin_key&wstoken=\(token)")!
    }

    private actor Renewals {
        private(set) var count = 0
        func record() { count += 1 }
    }

    private static func requestKey(
        token: String?,
        privateToken: String?,
        renewals: Renewals = Renewals()
    ) async throws -> MoodleAutologinService.Key? {
        try await MoodleAutologinService.requestKey(
            tokens: MoodleWebserviceClient.TokenSource(
                stored: { token },
                renew: { _ in
                    await renewals.record()
                    throw MoodleWebserviceError.missingStoredCredentials
                }
            ),
            privateToken: { privateToken },
            userId: { _ in 42 },
            session: session(),
            siteURL: site
        )
    }

    private static func answer(_ body: String, token: String) {
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data(body.utf8)), for: endpoint(token: token))
    }

    @Test("the private token goes in the POST body under the stored token, never in the query")
    func requestShape() async throws {
        let token = UUID().uuidString
        Self.answer(#"{"key":"k3y","autologinurl":"\#(Self.autologinLink)","warnings":[]}"#, token: token)

        let key = try #require(try await Self.requestKey(token: token, privateToken: "pr1vate"))
        #expect(key.userId == 42)
        #expect(key.value == "k3y")
        #expect(key.autologinURL == Self.autologinLink)

        let request = try #require(SettingsAPIStub.requests(for: Self.endpoint(token: token)).first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.query?.contains("privatetoken") == false)
        let body = SettingsAPIStub.bodyData(from: request).flatMap { String(data: $0, encoding: .utf8) }
        #expect(body == "privatetoken=pr1vate")
    }

    @Test("a renewed token sends the private token stored with it")
    func renewedTokenSendsItsOwnPrivateToken() async throws {
        let old = UUID().uuidString
        let new = UUID().uuidString
        Self.answer(#"{"exception":"moodle_exception","errorcode":"invalidtoken"}"#, token: old)
        Self.answer(#"{"key":"k3y","autologinurl":"\#(Self.autologinLink)","warnings":[]}"#, token: new)
        let stored = OSAllocatedUnfairLock<String?>(initialState: "pr1vate")

        let key = try await MoodleAutologinService.requestKey(
            tokens: MoodleWebserviceClient.TokenSource(
                stored: { old },
                renew: { _ in
                    stored.withLock { $0 = "r3newed" }
                    return new
                }
            ),
            privateToken: { stored.withLock { $0 } },
            userId: { _ in 42 },
            session: Self.session(),
            siteURL: Self.site
        )

        #expect(key?.value == "k3y")
        let request = try #require(SettingsAPIStub.requests(for: Self.endpoint(token: new)).first)
        let body = SettingsAPIStub.bodyData(from: request).flatMap { String(data: $0, encoding: .utf8) }
        #expect(body == "privatetoken=r3newed")
    }

    @Test("without a private token nothing is sent and no token is renewed")
    func noPrivateToken() async throws {
        let token = UUID().uuidString
        let renewals = Renewals()
        #expect(try await Self.requestKey(token: token, privateToken: nil, renewals: renewals) == nil)
        #expect(try await Self.requestKey(token: nil, privateToken: nil, renewals: renewals) == nil)
        #expect(SettingsAPIStub.requests(for: Self.endpoint(token: token)).isEmpty)
        #expect(await renewals.count == 0)
    }

    @Test("a Moodle error or a malformed answer opens the page as it is after one request", arguments: [
        #"{"exception":"moodle_exception","errorcode":"autologinkeygenerationlockout","message":"locked"}"#,
        #"{"exception":"moodle_exception","errorcode":"invalidprivatetoken","message":"invalid"}"#,
        #"{"key":"k3y","warnings":[]}"#,
        #"{"autologinurl":"https://moodle2.ntust.edu.tw/admin/tool/mobile/autologin.php","warnings":[]}"#,
        "<html>Service Unavailable</html>",
    ])
    func failedAnswer(_ body: String) async {
        let token = UUID().uuidString
        Self.answer(body, token: token)
        let service = Self.service {
            try await Self.requestKey(token: token, privateToken: "pr1vate")
        }

        #expect(await service.url(for: Self.page) == Self.page)
        #expect(SettingsAPIStub.requests(for: Self.endpoint(token: token)).count == 1)
    }
}
