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
        ("service-6", [("Licensed Software", "/e")]),
    ])

    private static let request = InformationSystemViewModel.Request(
        studentId: "B00000000", password: "not-a-password", language: .en, signIn: testSignIn
    )

    /// With `saved`, the links an earlier visit saved, which the page shows from its first frame.
    private static func store(_ school: FakePortalSchool, in folder: Folder, saved: Bool) -> PortalLinks {
        let files = PortalLinkFiles(folders: CacheFolders(root: folder.root))
        if saved, let links = NTUSTPortalParser.links(in: page, pageURL: PortalPages.pageURL) {
            files.save(.init(links: links, fetchedAt: Date()), studentId: request.studentId, language: request.language)
        }
        return PortalLinks(files: files, service: school.service, failures: PortalLinks.Failures())
    }

    private static func show(
        _ request: InformationSystemViewModel.Request?, store: PortalLinks, opened: OpenedURLs = OpenedURLs()
    ) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 812)
        let page = InformationSystemPage(
            request: request, policy: VisualStylePolicy(preset: .default), onSignIn: {}, store: store
        )
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

    /// The chip row scrolls sideways, so its chips past the edge are left out.
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

    @Test("signed out, the page asks to sign in, with no search")
    func signedOut() async throws {
        try await withAccessibilityAutomation {
            let window = try Self.show(nil, store: Self.store(FakePortalSchool(), in: Folder(), saved: true))
            defer { Self.close(window) }

            try await waitUntil { Self.shows(String(localized: "common_not_signed_in"), in: window) }

            #expect(Self.shows(String(localized: "onboarding_sign_in_button"), in: window))
            #expect(window.descendants(ofType: UISearchBar.self).isEmpty)
            try Self.expectNoOverflow(in: window)
            try await Self.save(window, as: "infosys-signed-out")
        }
    }

    @Test("a failed first load shows the failure's message with a retry, and no search")
    func failure() async throws {
        try await withAccessibilityAutomation {
            let folder = Folder()
            let school = FakePortalSchool()
            school.failure = URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: Self.timedOut])
            let window = try Self.show(Self.request, store: Self.store(school, in: folder, saved: false))
            defer { Self.close(window) }

            try await waitUntil { Self.shows(String(localized: "information_system_load_failed"), in: window) }

            #expect(Self.shows(Self.timedOut, in: window))
            #expect(window.descendants(ofType: UISearchBar.self).isEmpty)
            #expect(Self.shows(String(localized: "action_retry"), in: window))
            try Self.expectNoOverflow(in: window)
            try await Self.save(window, as: "infosys-failure")
        }
    }
}
#endif
