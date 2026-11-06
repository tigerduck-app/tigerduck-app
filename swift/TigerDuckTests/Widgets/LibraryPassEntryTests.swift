#if os(iOS)
import Foundation
import Testing
import UIKit
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct LibraryPassEntryTests {
    @Test func theWidgetsLinkOpensTheLibraryPage() {
        #expect(Self.destination(of: AppLink.libraryPass) == .library)
    }

    @Test func theQuickActionOpensTheWidgetsLink() throws {
        let declared = try #require(Self.quickActions.first)
        #expect(declared["UIApplicationShortcutItemIconSymbolName"] as? String == "qrcode")
        let type = try #require(declared["UIApplicationShortcutItemType"] as? String)
        var opened: [URL] = []
        #expect(QuickActionSceneDelegate.open(UIApplicationShortcutItem(type: type, localizedTitle: "")) { opened.append($0) })
        #expect(opened == [AppLink.libraryPass])
        #expect(opened.map(Self.destination(of:)) == [.library])
    }

    @Test func theQuickActionDelegateLeavesLinksToSwiftUI() {
        let linkCallbacks = [
            #selector(UISceneDelegate.scene(_:openURLContexts:)),
            #selector(UISceneDelegate.scene(_:continue:)),
            #selector(UISceneDelegate.scene(_:willContinueUserActivityWithType:)),
        ]
        #expect(linkCallbacks.filter(QuickActionSceneDelegate.instancesRespond(to:)).isEmpty)
    }

    @Test(arguments: ["en", "zh-Hant"])
    func theQuickActionIsTitledAsThePass(localization: String) throws {
        let declared = try #require(Self.quickActions.first)
        let key = try #require(declared["UIApplicationShortcutItemTitle"] as? String)
        let title = try #require(Self.strings("InfoPlist", localization)[key])
        #expect(title == Self.strings("Localizable", localization)["library_virtual_pass_title"])
    }

    @Test func theControlOpensTheWidgetsLink() async throws {
        let appsOpen = AppLink.open
        defer { AppLink.open = appsOpen }
        var opened: [URL] = []
        AppLink.open = { opened.append($0) }
        _ = try await OpenLibraryPassIntent().perform()
        #expect(opened == [AppLink.libraryPass])
        #expect(opened.map(Self.destination(of:)) == [.library])
    }

    @Test(arguments: [("en", "Open virtual pass"), ("zh-Hant", "開啟虛擬入館證")])
    func theActionButtonHintIsTranslated(localization: String, hint: String) throws {
        let widgets = try #require(
            Bundle.main.builtInPlugInsURL.flatMap { Bundle(url: $0.appending(path: "TigerDuckWidgetsExtension.appex")) }
        )
        #expect(Self.strings("Localizable", localization, in: widgets)["library_virtual_pass_action_hint"] == hint)
        #expect(Self.strings("Localizable", localization)["library_virtual_pass_action_hint"] == hint)
    }

    private static var quickActions: [[String: Any]] {
        Bundle.main.object(forInfoDictionaryKey: "UIApplicationShortcutItems") as? [[String: Any]] ?? []
    }

    private static func destination(of url: URL) -> WidgetDestination? {
        let router = AppRouter()
        router.open(url, signIn: SignInSeries().currentSignIn)
        return router.pendingWidgetDestination
    }

    private static func strings(_ table: String, _ localization: String, in bundle: Bundle = .main) -> [String: String] {
        let path = bundle.path(forResource: table, ofType: "strings", inDirectory: nil, forLocalization: localization)
        return path.flatMap { NSDictionary(contentsOfFile: $0) as? [String: String] } ?? [:]
    }
}
#endif
