#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct InformationSystemPageTests {
    private static let width: CGFloat = 375
    private static let longName =
        "Graduate school entrance examination registration, fee payment and admission ticket printing"
    private static let longMiss = "quantum chromodynamics lecture recordings from the previous academic year"
    /// What URLSession puts in a timed-out request's error, in English.
    private static let timedOut = "The request timed out."

    /// Records what the page opened; `OpenURLAction`'s handler is `@Sendable`.
    private final class OpenedURLs: @unchecked Sendable {
        var urls: [URL] = []
    }

    private final class Folder {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("InformationSystemPageTests-\(UUID().uuidString)", isDirectory: true)

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private static let page = PortalPages.page([
        ("service-1", [("Course Selection", "/a"), (longName, "/b")]),
        ("service-2", [("Student Record", "/c")]),
        ("service-3", [("Dormitory", "/d")]),
        ("service-6", [("Licensed Software", "https://www.cc.ntust.edu.tw/p/412-1050-8701.php?Lang=en")]),
    ])

    private static let request = InformationSystemViewModel.Request(
        studentId: "B00000000", password: "not-a-password", language: .en, signIn: testSignIn
    )

    private static func store(_ school: FakePortalSchool, in folder: Folder, saved: Bool) -> PortalLinks {
        let files = PortalLinkFiles(folders: CacheFolders(root: folder.root))
        if saved, let links = NTUSTPortalParser.links(in: page, pageURL: PortalPages.pageURL) {
            files.save(.init(links: links, fetchedAt: Date()), studentId: request.studentId, language: request.language)
        }
        return PortalLinks(files: files, service: school.service, unreadablePages: PortalLinks.UnreadablePages())
    }

    @Observable
    fileprivate final class Keychain {
        var request: InformationSystemViewModel.Request?

        init(_ request: InformationSystemViewModel.Request?) { self.request = request }
    }

    private struct Host: View {
        let keychain: Keychain
        let signedIn: Bool
        let store: PortalLinks

        var body: some View {
            InformationSystemPage(
                request: keychain.request, signedIn: signedIn, policy: VisualStylePolicy(preset: .default), onSignIn: {},
                store: store
            )
        }
    }

    private static func show(
        _ request: InformationSystemViewModel.Request?, signedIn: Bool = true, store: PortalLinks,
        opened: OpenedURLs = OpenedURLs()
    ) throws -> UIWindow {
        try show(Keychain(request), signedIn: signedIn, store: store, opened: opened)
    }

    private static func show(
        _ keychain: Keychain, signedIn: Bool, store: PortalLinks, opened: OpenedURLs = OpenedURLs()
    ) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 812)
        let page = Host(keychain: keychain, signedIn: signedIn, store: store)
        // In a tab, as the app shows it, where the search field waits in the navigation bar.
        let feature = AppFeature.informationSystem
        let tabs = TabView {
            Tab(feature.tabBarDisplayName, systemImage: feature.iconName) { NavigationStack { page } }
        }
        window.rootViewController = UIHostingController(rootView: tabs
            .environment(\.openURL, OpenURLAction { opened.urls.append($0); return .handled }))
        window.makeKeyAndVisible()
        return window
    }

    private static func search(_ query: String, in window: UIWindow) async throws {
        try await waitUntil { window.descendants(ofType: UIScrollView.self).first.map { $0.contentSize.height > 0 } ?? false }
        let list = try #require(window.descendants(ofType: UIScrollView.self).first)
        list.contentOffset.y = -list.adjustedContentInset.top - 60
        try await waitUntil { !window.descendants(ofType: UITextField.self).isEmpty }
        let field = try #require(window.descendants(ofType: UITextField.self).first)
        field.becomeFirstResponder()
        try await waitUntil { field.isFirstResponder }
        field.insertText(query)
        list.contentOffset.y = -list.adjustedContentInset.top
    }

    /// A list keeps the cells of rows it no longer shows, hidden, for reuse.
    private static func labels(in window: UIWindow) -> [String] {
        guard let root = window.rootViewController?.view else { return [] }
        let shown: [UIView] = root.descendants(ofType: UICollectionView.self).first?.visibleCells ?? [root]
        return shown.flatMap { exposedAccessibilityLabels(in: $0) }
    }

    private static func shows(_ text: String, in window: UIWindow) -> Bool {
        labels(in: window).contains { $0.contains(text) }
    }

    private static func expectNoOverflow(in window: UIWindow, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let root = try #require(window.rootViewController?.view)
        let chips = Set(PortalCategory.allCases.map { String(localized: $0.titleKey) })
        let wide = exposedAccessibilityElements(in: root).filter {
            ($0.accessibilityFrame.minX < -0.5 || $0.accessibilityFrame.maxX > window.bounds.width + 0.5)
                && !($0.accessibilityTraits.contains(.button) && chips.contains($0.accessibilityLabel ?? ""))
        }
        #expect(wide.isEmpty, "\(wide.map { $0.accessibilityLabel ?? "" })", sourceLocation: sourceLocation)
    }

    private static func save(_ window: UIWindow, as name: String) async throws {
        try await Task.sleep(for: .milliseconds(400))
        window.saveSnapshot(as: name)
    }

    private static func close(_ window: UIWindow) {
        window.endEditing(true)
        window.isHidden = true
    }

    @Test("saved links show from the first frame under their categories, with the search attached and a long name inside the width, and a row opens its link")
    func list() async throws {
        try await withAccessibilityAutomation {
            let folder = Folder()
            let school = FakePortalSchool()
            school.pages = [Self.page]
            let opened = OpenedURLs()
            let window = try Self.show(Self.request, store: Self.store(school, in: folder, saved: true), opened: opened)
            defer { Self.close(window) }

            try await waitUntil {
                Self.shows(Self.longName, in: window) && Self.shows(String(localized: "information_system_all_services"), in: window)
            }

            #expect(Self.shows(String(localized: PortalCategory.curriculum.titleKey), in: window))
            #expect(Self.shows("Licensed Software", in: window))
            #expect(Self.shows(String(localized: "information_system_campus_network_only"), in: window))
            try await waitUntil { !window.descendants(ofType: UISearchBar.self).isEmpty }
            #expect(school.loads.isEmpty)
            try Self.expectNoOverflow(in: window)
            try await Self.save(window, as: "infosys-list")

            let root = try #require(window.rootViewController?.view)
            let row = try #require(accessibilityElement(labeled: Self.longName, in: root))
            row.accessibilityActivate()
            try await waitUntil { !opened.urls.isEmpty }
            #expect(opened.urls == [URL(string: "https://i.ntust.edu.tw/b")!])
        }
    }

    @Test("a search keeps only the matching links, inside the width")
    func searchActive() async throws {
        try await withAccessibilityAutomation {
            let folder = Folder()
            let school = FakePortalSchool()
            school.pages = [Self.page]
            let window = try Self.show(Self.request, store: Self.store(school, in: folder, saved: true))
            defer { Self.close(window) }

            try await Self.search("admission ticket", in: window)
            try await waitUntil { !Self.shows("Student Record", in: window) }

            #expect(Self.shows(Self.longName, in: window))
            #expect(!Self.shows("Course Selection", in: window))
            try Self.expectNoOverflow(in: window)
            try await Self.save(window, as: "infosys-search")
        }
    }

    @Test("a tap on a result while the search is active reaches the row, opens its link and keeps the search")
    func tapWhileSearching() async throws {
        try await withAccessibilityAutomation {
            let folder = Folder()
            let school = FakePortalSchool()
            school.pages = [Self.page]
            let opened = OpenedURLs()
            let window = try Self.show(Self.request, store: Self.store(school, in: folder, saved: true), opened: opened)
            defer { Self.close(window) }

            try await Self.search("admission ticket", in: window)
            try await waitUntil { !Self.shows("Student Record", in: window) }
            let field = try #require(window.descendants(ofType: UISearchBar.self).first?.searchTextField)
            #expect(field.isFirstResponder)

            let root = try #require(window.rootViewController?.view)
            let row = try #require(accessibilityElement(labeled: Self.longName, in: root))
            let list = try #require(window.descendants(ofType: UICollectionView.self).first)
            let hit = window.hitTest(CGPoint(x: row.accessibilityFrame.midX, y: row.accessibilityFrame.midY), with: nil)
            #expect(hit?.isDescendant(of: list) == true, "\(hit.map { "\(type(of: $0))" } ?? "nothing") takes the tap")

            row.accessibilityActivate()
            try await waitUntil { !opened.urls.isEmpty }
            #expect(opened.urls == [URL(string: "https://i.ntust.edu.tw/b")!])
            #expect(field.text == "admission ticket")
            #expect(Self.shows(Self.longName, in: window))
        }
    }

    @Test("a search that matches nothing shows the empty search state, inside the width")
    func searchEmpty() async throws {
        try await withAccessibilityAutomation {
            let folder = Folder()
            let school = FakePortalSchool()
            school.pages = [Self.page]
            let window = try Self.show(Self.request, store: Self.store(school, in: folder, saved: true))
            defer { Self.close(window) }

            try await Self.search(Self.longMiss, in: window)
            try await waitUntil { Self.shows(Self.longMiss, in: window) && !Self.shows("Student Record", in: window) }

            #expect(!Self.shows(Self.longName, in: window))
            try Self.expectNoOverflow(in: window)
            try await Self.save(window, as: "infosys-search-empty")
        }
    }

    @Test("signed out, the page asks to sign in")
    func signedOut() async throws {
        try await withAccessibilityAutomation {
            let window = try Self.show(nil, signedIn: false, store: Self.store(FakePortalSchool(), in: Folder(), saved: true))
            defer { Self.close(window) }

            try await waitUntil { Self.shows(String(localized: "common_not_signed_in"), in: window) }

            #expect(Self.shows(String(localized: "onboarding_sign_in_button"), in: window))
            try Self.expectNoOverflow(in: window)
            try await Self.save(window, as: "infosys-signed-out")
        }
    }

    @Test("signed in before the first unlock, the page waits without a sign-in prompt and loads once the Keychain reads")
    func lockedKeychain() async throws {
        try await withAccessibilityAutomation {
            let folder = Folder()
            let school = FakePortalSchool()
            let keychain = Keychain(nil)
            let window = try Self.show(keychain, signedIn: true, store: Self.store(school, in: folder, saved: true))
            defer { Self.close(window) }

            try await waitUntil { !window.descendants(ofType: UICollectionView.self).isEmpty }
            try await Task.sleep(for: .milliseconds(300))
            #expect(!Self.shows(String(localized: "common_not_signed_in"), in: window))
            #expect(!Self.shows(String(localized: "onboarding_sign_in_button"), in: window))

            keychain.request = Self.request
            try await waitUntil { Self.shows("Licensed Software", in: window) }
            #expect(school.loads.isEmpty)
        }
    }

    @Test("a failed first load shows the failure's message with a retry")
    func failure() async throws {
        try await withAccessibilityAutomation {
            let folder = Folder()
            let school = FakePortalSchool()
            school.failure = URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: Self.timedOut])
            let window = try Self.show(Self.request, store: Self.store(school, in: folder, saved: false))
            defer { Self.close(window) }

            try await waitUntil { Self.shows(String(localized: "information_system_load_failed"), in: window) }

            #expect(Self.shows(Self.timedOut, in: window))
            #expect(Self.shows(String(localized: "action_retry"), in: window))
            try Self.expectNoOverflow(in: window)
            try await Self.save(window, as: "infosys-failure")
        }
    }
}
#endif
