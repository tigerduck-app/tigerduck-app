import Foundation
import Testing
@testable import TigerDuck

/// A school that answers the portal's page from memory, for the portal's service and store.
@MainActor
final class FakePortalSchool {
    /// The page each load answers with, the last one repeating; nil answers with the sign-in form.
    var pages: [String?] = [PortalPages.full]
    var signsIn = true
    var failure: (any Error)?
    var holds = false
    private(set) var loads: [URL] = []
    private(set) var signIns = 0
    private var held: [CheckedContinuation<Void, Never>] = []

    var isHolding: Bool { !held.isEmpty }

    var service: NTUSTPortalService {
        NTUSTPortalService(load: { try await self.load($0) }, signIn: { _, _ in
            self.signIns += 1
            return self.signsIn
        })
    }

    func release() {
        held.forEach { $0.resume() }
        held = []
    }

    private func load(_ url: URL) async throws -> (Data, URLResponse) {
        loads.append(url)
        if holds { await withCheckedContinuation { held.append($0) } }
        if let failure { throw failure }
        let page = pages.count > 1 ? pages.removeFirst() : pages.first ?? nil
        let landed = page == nil ? URL(string: "https://ssoam2.ntust.edu.tw/account/login")! : url
        let response = HTTPURLResponse(
            url: landed, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        return (Data((page ?? "<form id=\"loginForm\"></form>").utf8), response)
    }
}

@MainActor
struct NTUSTPortalServiceTests {
    private static func credentials(_ signIn: SignIn = testSignIn) -> NTUSTPortalService.Credentials {
        .init(studentId: "B00000000", password: "not-a-password", signIn: signIn)
    }

    @Test("Chinese reads the Chinese page, and English and every other language the English one", arguments: [
        ("zh-Hant", "https://i.ntust.edu.tw/student"),
        ("zh-Hans", "https://i.ntust.edu.tw/student"),
        ("en", "https://i.ntust.edu.tw/EN/student"),
        ("ja", "https://i.ntust.edu.tw/EN/student"),
        ("ko", "https://i.ntust.edu.tw/EN/student"),
    ])
    func languageChoosesThePage(appLanguage: String, page: String) {
        #expect(PortalLanguage(appLanguage: appLanguage).pageURL.absoluteString == page)
    }

    @Test("a live session reads the page once and does not sign in")
    func liveSession() async throws {
        let school = FakePortalSchool()

        let links = try await school.service.links(in: .en, credentials: Self.credentials())

        #expect(links.count == 6)
        #expect(school.loads == [PortalLanguage.en.pageURL])
        #expect(school.signIns == 0)
    }

    @Test("a page sent to the sign-in signs in and reads it again")
    func signsInWhenBounced() async throws {
        let school = FakePortalSchool()
        school.pages = [nil, PortalPages.full]

        let links = try await school.service.links(in: .zh, credentials: Self.credentials())

        #expect(links.count == 6)
        #expect(school.loads == [PortalLanguage.zh.pageURL, PortalLanguage.zh.pageURL])
        #expect(school.signIns == 1)
    }

    @Test("a refused sign-in is not signed in, and a page still unread after one is unreadable")
    func failures() async throws {
        let refused = FakePortalSchool()
        refused.pages = [nil]
        refused.signsIn = false
        await #expect(throws: NTUSTPortalError.notSignedIn) {
            try await refused.service.links(in: .zh, credentials: Self.credentials())
        }

        let changed = FakePortalSchool()
        changed.pages = ["<html><body>Redesigned</body></html>"]
        await #expect(throws: NTUSTPortalError.unreadable) {
            try await changed.service.links(in: .zh, credentials: Self.credentials())
        }
        #expect(changed.signIns == 1)
    }

    @Test("a sign-in that ended does not sign in again")
    func endedSignIn() async throws {
        let school = FakePortalSchool()
        school.pages = [nil]

        await #expect(throws: CancellationError.self) {
            try await school.service.links(in: .zh, credentials: Self.credentials(endedTestSignIn))
        }
        #expect(school.signIns == 0)
    }
}
