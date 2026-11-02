import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct InformationSystemViewModelTests {
    private typealias Request = InformationSystemViewModel.Request

    @MainActor
    private final class Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("InformationSystemViewModelTests-\(UUID().uuidString)", isDirectory: true)
        let school = FakePortalSchool()
        let session = AccountSession()
        let unreadablePages = PortalLinks.UnreadablePages()
        var now = Date()
        var demoLinks: [PortalLink] = []

        lazy var folders = CacheFolders(root: root)
        lazy var files = PortalLinkFiles(folders: folders)

        var store: PortalLinks {
            PortalLinks(
                files: files, service: school.service, unreadablePages: unreadablePages, demoLinks: { _ in self.demoLinks }, now: { self.now }
            )
        }

        func request(_ studentId: String = "B00000001", _ language: PortalLanguage = .zh) -> Request {
            Request(studentId: studentId, password: "not-a-password", language: language, signIn: session.signIns.currentSignIn)
        }

        func save(_ names: [String], for studentId: String, _ language: PortalLanguage, at date: Date) {
            let links = names.map { PortalLink(category: .curriculum, name: $0, url: URL(string: "https://x.ntust.edu.tw/\($0)")!) }
            files.save(.init(links: links, fetchedAt: date), studentId: studentId, language: language)
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    @Test("the saved links of the account and language show, and fresh ones are not read again")
    func savedLinksShowFirst() async {
        let harness = Harness()
        harness.save(["Saved"], for: "B00000001", .zh, at: harness.now)
        let model = InformationSystemViewModel(store: harness.store)

        await model.open(harness.request())

        #expect(model.links.map(\.name) == ["Saved"])
        #expect(harness.school.loads.isEmpty)
    }

    @Test("links are kept per account and per language, and another one's links show with no chip or search")
    func cachePerAccountAndLanguage() async {
        let harness = Harness()
        harness.save(["Chinese"], for: "B00000001", .zh, at: harness.now)
        harness.save(["English"], for: "B00000001", .en, at: harness.now)
        harness.save(["Other student"], for: "B00000002", .zh, at: harness.now)
        let model = InformationSystemViewModel(store: harness.store)

        await model.open(harness.request("B00000001", .en))
        #expect(model.links.map(\.name) == ["English"])
        model.query = "English"
        model.category = .resources
        await model.open(harness.request("B00000002", .zh))
        #expect(model.links.map(\.name) == ["Other student"])
        #expect(model.query.isEmpty)
        #expect(model.category == nil)
        await model.open(harness.request("B00000001", .zh))
        #expect(model.links.map(\.name) == ["Chinese"])
        #expect(harness.school.loads.isEmpty)
    }

    @Test("old saved links show while the school's are read, which replace and are saved")
    func staleLinksRefresh() async throws {
        let harness = Harness()
        harness.save(["Old"], for: "B00000001", .zh, at: harness.now.addingTimeInterval(-2 * 86_400))
        harness.school.holds = true
        let model = InformationSystemViewModel(store: harness.store)

        let opening = Task { await model.open(harness.request()) }
        try await waitUntil { harness.school.isHolding }
        #expect(model.links.map(\.name) == ["Old"])
        #expect(model.phase == .loading)
        harness.school.release()
        await opening.value

        #expect(model.links.count == 6)
        #expect(model.phase == .idle)
        #expect(harness.files.load(studentId: "B00000001", language: .zh)?.links.count == 6)
    }

    @Test("a language change shows that language's links and reads its page")
    func languageChangeReloads() async {
        let harness = Harness()
        let model = InformationSystemViewModel(store: harness.store)

        await model.open(harness.request("B00000001", .zh))
        await model.open(harness.request("B00000001", .en))

        #expect(harness.school.loads == [PortalLanguage.zh.pageURL, PortalLanguage.en.pageURL])
        #expect(harness.files.load(studentId: "B00000001", language: .en) != nil)
    }

    @Test("the school sign-out deletes the saved links")
    func signOutClears() {
        let harness = Harness()
        harness.save(["Saved"], for: "B00000001", .zh, at: harness.now)
        harness.save(["Saved"], for: "B00000001", .en, at: harness.now)

        #expect(SignOutPlan.schoolStores.contains { $0 == PortalLinkFiles.self })
        for store in SignOutPlan.schoolStores where store == PortalLinkFiles.self {
            store.forgetAccount(in: AccountStorage(folders: harness.folders))
        }

        #expect(harness.files.load(studentId: "B00000001", language: .zh) == nil)
        #expect(harness.files.load(studentId: "B00000001", language: .en) == nil)
    }

    @Test("a load that ends after the account signs out is neither shown nor saved")
    func loadAfterSignOutIsDropped() async throws {
        let harness = Harness()
        harness.school.holds = true
        let model = InformationSystemViewModel(store: harness.store)

        let opening = Task { await model.open(harness.request()) }
        try await waitUntil { harness.school.isHolding }
        harness.session.endSignIn()
        await model.open(nil)
        harness.school.release()
        await opening.value

        #expect(model.links.isEmpty)
        #expect(model.phase == .idle)
        #expect(harness.files.load(studentId: "B00000001", language: .zh) == nil)
    }

    @Test("a load that ends after another account signs in is not shown")
    func loadAfterAccountSwitchIsDropped() async throws {
        let harness = Harness()
        harness.save(["Second"], for: "B00000002", .zh, at: harness.now)
        harness.school.holds = true
        let model = InformationSystemViewModel(store: harness.store)

        let opening = Task { await model.open(harness.request("B00000001")) }
        try await waitUntil { harness.school.isHolding }
        harness.session.endSignIn()
        await model.open(harness.request("B00000002"))
        harness.school.release()
        await opening.value

        #expect(model.links.map(\.name) == ["Second"])
        #expect(harness.files.load(studentId: "B00000001", language: .zh) == nil)
    }

    @Test("a failed first load shows its failure, which a retry reads again")
    func failedFirstLoadRetries() async {
        let harness = Harness()
        harness.school.failure = URLError(.notConnectedToInternet)
        let model = InformationSystemViewModel(store: harness.store)

        await model.open(harness.request())
        #expect(model.phase == .failed(URLError(.notConnectedToInternet).localizedDescription))
        #expect(model.status == .failed)

        harness.school.failure = nil
        await model.refresh()

        #expect(model.links.count == 6)
        #expect(model.phase == .idle)
        #expect(model.status == .ok)
        #expect(harness.school.loads.count == 2)
    }

    @Test("a portal page with no links counts as an answer: opening again within a day asks nothing, a pull does")
    func failureCountsTowardFreshness() async {
        let harness = Harness()
        harness.school.pages = [nil]
        let first = InformationSystemViewModel(store: harness.store)

        await first.open(harness.request())
        #expect(first.phase == .failed(NTUSTPortalError.unreadable.localizedDescription))
        #expect(harness.school.signIns == 1)

        let reopened = InformationSystemViewModel(store: harness.store)
        await reopened.open(harness.request())
        #expect(reopened.phase == .failed(NTUSTPortalError.unreadable.localizedDescription))
        #expect(harness.school.loads.count == 2)
        #expect(harness.school.signIns == 1)

        harness.now = harness.now.addingTimeInterval(PortalLinks.freshness.lifetime)
        await reopened.open(harness.request())
        #expect(harness.school.signIns == 2)

        harness.school.pages = [PortalPages.full]
        await reopened.refresh()
        #expect(reopened.links.count == 6)
        #expect(InformationSystemViewModel(store: harness.store, showing: harness.request()).status == .ok)
    }

    @Test("a portal page with no links is kept for its account only, and the school sign-out forgets it")
    func unreadableAnswerIsPerAccount() async {
        let harness = Harness()
        harness.school.pages = [nil]
        await InformationSystemViewModel(store: harness.store).open(harness.request("B00000001"))
        #expect(harness.school.signIns == 1)

        harness.school.pages = [PortalPages.full]
        let other = InformationSystemViewModel(store: harness.store)
        await other.open(harness.request("B00000002"))
        #expect(other.links.count == 6)

        harness.school.pages = [nil]
        var shared = harness.store
        shared.unreadablePages = .shared
        _ = try? await shared.fetch(studentId: "B00000001", password: "not-a-password", language: .zh, for: harness.session.signIns.currentSignIn)
        #expect(shared.recentUnreadablePage(studentId: "B00000001", language: .zh, for: harness.session.signIns.currentSignIn) != nil)
        #expect(SignOutPlan.schoolStores.contains { $0 == PortalLinks.UnreadablePages.self })
        for store in SignOutPlan.schoolStores where store == PortalLinks.UnreadablePages.self {
            store.forgetAccount(in: AccountStorage(folders: harness.folders))
        }
        #expect(shared.recentUnreadablePage(studentId: "B00000001", language: .zh, for: harness.session.signIns.currentSignIn) == nil)
    }

    @Test("a network failure is not kept: the next open reads the school again")
    func networkFailureIsNotKept() async {
        let harness = Harness()
        harness.school.failure = URLError(.notConnectedToInternet)

        await InformationSystemViewModel(store: harness.store).open(harness.request())
        #expect(harness.school.loads.count == 1)

        harness.school.failure = nil
        let reopened = InformationSystemViewModel(store: harness.store)
        await reopened.open(harness.request())

        #expect(harness.school.loads.count == 2)
        #expect(reopened.links.count == 6)
        #expect(reopened.phase == .idle)
    }

    @Test("a pull that fails while links show keeps them and turns the status to failed")
    func failedRefreshKeepsLinks() async {
        let harness = Harness()
        harness.save(["Saved"], for: "B00000001", .zh, at: harness.now)
        let model = InformationSystemViewModel(store: harness.store, showing: harness.request())
        #expect(model.links.map(\.name) == ["Saved"])
        #expect(model.status == .ok)

        harness.school.failure = URLError(.timedOut)
        await model.refresh()

        #expect(model.links.map(\.name) == ["Saved"])
        #expect(model.status == .failed)
    }

    @Test("a load cancelled with the page shows no failure")
    func cancelledLoad() async throws {
        let harness = Harness()
        harness.school.failure = CancellationError()
        let model = InformationSystemViewModel(store: harness.store)

        await model.open(harness.request())

        #expect(model.phase == .idle)
    }

    @Test("the shown sections follow the chip and the search")
    func sectionsFollowFilters() async {
        let harness = Harness()
        let model = InformationSystemViewModel(store: harness.store)
        await model.open(harness.request())
        #expect(model.sections.count == 6)

        model.category = .curriculum
        #expect(model.sections.map(\.category) == [.curriculum])
        model.query = "授權"
        #expect(model.sections.isEmpty)
        model.category = nil
        #expect(model.sections.map(\.category) == [.resources])
    }

    @Test("a demo link never goes to the system browser, which the Mac opens links in, and the phone's browser keeps it")
    func demoLinkTarget() {
        let link = PortalLink(category: .curriculum, name: "Course Selection", url: URL(string: "https://courseselection.ntust.edu.tw/")!)

        #expect(InformationSystemViewModel.target(of: link, isDemo: true, browser: .system) == .demoPage(link))
        #expect(InformationSystemViewModel.target(of: link, isDemo: false, browser: .system) == .address(link.url))
        #expect(InformationSystemViewModel.target(of: link, isDemo: true, browser: .inApp) == .address(link.url))
        #expect(InformationSystemViewModel.target(of: link, isDemo: false, browser: .inApp) == .address(link.url))
    }

    @Test("the demo account's links come from the demo, not the school")
    func demoLinks() async {
        let harness = Harness()
        harness.demoLinks = [PortalLink(category: .resources, name: "Demo", url: URL(string: "https://www.lib.ntust.edu.tw/")!)]
        let model = InformationSystemViewModel(store: harness.store)
        harness.session.startDemoSignIn()

        await model.open(harness.request())

        #expect(model.links.map(\.name) == ["Demo"])
        #expect(harness.school.loads.isEmpty)
    }
}

@MainActor
struct InformationSystemFilterTests {
    private static let links = NTUSTPortalParser.links(in: PortalPages.page([
        ("service-1", [("選課系統", "/a"), ("Course Search", "/b")]),
        ("service-2", [("Résumé Office", "/c")]),
        ("service-6", [("授權軟體", "/d")]),
    ]), pageURL: PortalPages.pageURL) ?? []

    private static func names(_ category: PortalCategory?, _ query: String) -> [[String]] {
        InformationSystemViewModel.sections(of: links, in: category, matching: query).map { $0.links.map(\.name) }
    }

    @Test("every category shows in the portal's order with no chip and no search")
    func everything() {
        #expect(Self.names(nil, "") == [["選課系統", "Course Search"], ["Résumé Office"], ["授權軟體"]])
    }

    @Test("a chip shows only its category")
    func chip() {
        #expect(Self.names(.personalInfo, "") == [["Résumé Office"]])
        #expect(Self.names(.campusLife, "").isEmpty)
    }

    @Test("search matches link names ignoring case and diacritics, and category names")
    func search() {
        #expect(Self.names(nil, "course") == [["Course Search"]])
        #expect(Self.names(nil, "  RESUME ") == [["Résumé Office"]])
        #expect(Self.names(nil, String(localized: PortalCategory.resources.titleKey)) == [["授權軟體"]])
    }

    @Test("a chip and a search narrow together, and a miss leaves nothing")
    func chipAndSearch() {
        #expect(Self.names(.curriculum, "選課") == [["選課系統"]])
        #expect(Self.names(.personalInfo, "選課").isEmpty)
        #expect(Self.names(nil, "quantum chromodynamics").isEmpty)
    }

    @Test("only the graduates' leaving form, as the portal writes its address, does not open")
    func linksThatOpen() {
        func opens(_ address: String) -> Bool {
            PortalLink(category: .personalInfo, name: "x", url: URL(string: address)!).opens
        }
        #expect(!opens("https://StuInfoSys.ntust.edu.tw/SAGraduatesServ/SAGraduates"))
        #expect(!opens("https://stuinfosys.ntust.edu.tw/sagraduatesserv/"))
        #expect(opens("https://stuinfosys.ntust.edu.tw/StudentInformation"))
        #expect(opens("https://StuInfoSys.ntust.edu.tw/StuScoreQueryServ/StuScoreQuery"))
        #expect(opens("https://example.ntust.edu.tw/SAGraduatesServ/SAGraduates"))
    }
}
