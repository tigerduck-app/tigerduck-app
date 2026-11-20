#if os(iOS)
import Defaults
import Foundation
import Testing
import UIKit
@testable import TigerDuck

@MainActor
final class FakeAlternateIconHost: AlternateIconHost {
    struct Refused: Error {}

    var supportsAlternateIcons = true
    var alternateIconName: String?
    var refuses = false
    /// Keeps the next change waiting, after the new icon shows, until `release()`, as iOS does
    /// while its alert is up. Later changes return at once.
    var holds = false
    private(set) var requests: [String?] = []
    private var held: CheckedContinuation<Void, Never>?
    var isHolding: Bool { held != nil }

    init(showing name: String? = nil) {
        alternateIconName = name
    }

    func setAlternateIconName(_ alternateIconName: String?) async throws {
        requests.append(alternateIconName)
        if refuses { throw Refused() }
        self.alternateIconName = alternateIconName
        if holds {
            holds = false
            await withCheckedContinuation { held = $0 }
        }
    }

    func release() {
        held?.resume()
        held = nil
    }
}

@MainActor
@Suite(.serialized)
struct AppIconTests {
    private static let primary = AppIcon.naihu
    /// What is chosen, what iOS shows before, and what iOS is asked for.
    private static let choices: [(AppIcon?, String?, String?)] = [
        (nil, "TigerDuck", nil), (.naihu, "TigerDuck", nil), (.tigerDuck, nil, "TigerDuck"),
        (.tigerDuckChristmas, "TigerDuck", "TigerDuckChristmas"),
    ]

    /// Runs with the stored choice set to `stored`, and puts the device's own back afterwards.
    private static func withStoredChoice(_ stored: AppIcon?, _ body: () async throws -> Void) async rethrows {
        try await withExclusiveRealDefaults {
            let saved = Defaults[.appIcon]
            defer { Defaults[.appIcon] = saved }
            Defaults[.appIcon] = stored
            try await body()
        }
    }

    @Test("the picker lists the primary icon, then TigerDuck, Naihu and Christmas, each under its own key")
    func theChoicesAreInOrder() {
        #expect(AppIcon.choices == [nil, .tigerDuck, .naihu, .tigerDuckChristmas])
        #expect(AppIcon.choices.map { AppIcon.titleKey(of: $0).key } == [
            "settings_app_icon_default", "app_icon_name_tigerduck", "app_icon_name_naihu", "app_icon_name_tigerduck_christmas",
        ])
        for icon in AppIcon.choices {
            let label = AppIcon.titleKey(of: icon)
            #expect(String(localized: label) != label.key, "\(label.key) has no translation")
        }
    }

    @Test("the built app's primary icon is Naihu and every other icon ships as an alternate of its own name",
          arguments: ["CFBundleIcons", "CFBundleIcons~ipad"])
    func theBundleListsEveryIcon(key: String) throws {
        // Bundle's own lookup answers an iPhone with the iPhone's keys only, so the file is read whole.
        let url = try #require(Bundle.main.url(forResource: "Info", withExtension: "plist"))
        let plist = try #require(NSDictionary(contentsOf: url) as? [String: Any])
        let icons = try #require(plist[key] as? [String: Any])
        let primary = try #require(icons["CFBundlePrimaryIcon"] as? [String: Any])
        #expect(primary["CFBundleIconName"] as? String == Self.primary.rawValue)
        #expect(AppIcon.primary() == Self.primary)
        let alternates = try #require(icons["CFBundleAlternateIcons"] as? [String: [String: Any]])
        #expect(Set(alternates.keys) == Set(AppIcon.allCases.filter { $0 != Self.primary }.map(\.rawValue)))
        for (name, alternate) in alternates {
            #expect(alternate["CFBundleIconName"] as? String == name)
        }
    }

    @Test("every icon has its light and dark preview in the app")
    func everyIconHasAPreview() throws {
        for icon in AppIcon.allCases {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let image = UIImage(named: "\(icon.rawValue)Preview", in: .main, compatibleWith: UITraitCollection(userInterfaceStyle: style))
                #expect(image != nil, "\(icon) has no \(style == .dark ? "dark" : "light") preview")
            }
        }
    }

    @Test("the primary icon and the default both show as no alternate; any other icon as its own name")
    func alternateNames() {
        #expect(AppIconSwitch.alternateName(for: nil, primary: Self.primary) == nil)
        #expect(AppIconSwitch.alternateName(for: .naihu, primary: Self.primary) == nil)
        #expect(AppIconSwitch.alternateName(for: .tigerDuck, primary: Self.primary) == "TigerDuck")
        #expect(AppIconSwitch.alternateName(for: .tigerDuckChristmas, primary: Self.primary) == "TigerDuckChristmas")
        #expect(AppIconSwitch.alternateName(for: .naihu, primary: .tigerDuck) == "Naihu")
    }

    @Test("choosing an icon asks iOS for it, then stores the choice",
          arguments: choices)
    func choosing(choice: AppIcon?, showing: String?, asked: String?) async {
        await Self.withStoredChoice(.tigerDuck) {
            let host = FakeAlternateIconHost(showing: showing)

            await AppIconSwitch.choose(choice, host: host, primary: Self.primary)

            #expect(host.requests == [asked])
            #expect(host.alternateIconName == asked)
            #expect(Defaults[.appIcon] == choice)
        }
    }

    @Test("pinning the icon iOS already shows stores the choice without asking again")
    func pinningWhatIsShown() async {
        await Self.withStoredChoice(nil) {
            let host = FakeAlternateIconHost()

            await AppIconSwitch.choose(.naihu, host: host, primary: Self.primary)

            #expect(host.requests.isEmpty)
            #expect(Defaults[.appIcon] == .naihu)
        }
    }

    @Test("a device that cannot change its icon, or a change iOS refuses, keeps the icon and the choice it had")
    func refused() async {
        await Self.withStoredChoice(nil) {
            let unsupported = FakeAlternateIconHost()
            unsupported.supportsAlternateIcons = false
            await AppIconSwitch.choose(.tigerDuck, host: unsupported, primary: Self.primary)
            #expect(unsupported.requests.isEmpty)
            #expect(Defaults[.appIcon] == nil)

            let refusing = FakeAlternateIconHost()
            refusing.refuses = true
            await AppIconSwitch.choose(.tigerDuck, host: refusing, primary: Self.primary)
            #expect(refusing.requests == ["TigerDuck"])
            #expect(refusing.alternateIconName == nil)
            #expect(Defaults[.appIcon] == nil)
        }
    }

    @Test("after an update that changes the primary icon, a return to the app shows the pinned icon again")
    func reconcileAfterThePrimaryChanged() async {
        await Self.withStoredChoice(.naihu) {
            let host = FakeAlternateIconHost()
            await AppIconSwitch.reconcile(host: host, primary: .tigerDuck)
            #expect(host.requests == ["Naihu"])
        }
        await Self.withStoredChoice(.tigerDuck) {
            let host = FakeAlternateIconHost(showing: "TigerDuck")
            await AppIconSwitch.reconcile(host: host, primary: .tigerDuck)
            #expect(host.requests == [nil])
        }
    }

    @Test("a return to the app while iOS is still changing the icon asks nothing, so it cannot undo the change")
    func reconcileWhileChanging() async throws {
        try await Self.withStoredChoice(nil) {
            let host = FakeAlternateIconHost()
            host.holds = true
            let choosing = Task { await AppIconSwitch.choose(.tigerDuck, host: host, primary: Self.primary) }
            try await waitUntil { host.isHolding }

            await AppIconSwitch.reconcile(host: host, primary: Self.primary)
            host.release()
            await choosing.value

            #expect(host.requests == ["TigerDuck"])
            #expect(host.alternateIconName == "TigerDuck")
            #expect(Defaults[.appIcon] == .tigerDuck)
        }
    }

    @Test("a return to the app asks nothing while iOS shows the stored choice")
    func reconcileWhenShown() async {
        for (stored, showing) in [(AppIcon?.none, String?.none), (.naihu, nil), (.tigerDuck, "TigerDuck")] {
            await Self.withStoredChoice(stored) {
                let host = FakeAlternateIconHost(showing: showing)
                await AppIconSwitch.reconcile(host: host, primary: Self.primary)
                #expect(host.requests.isEmpty)
            }
        }
    }

    @Test("a stored name this build has no icon for reads as the default")
    func anUnknownStoredNameIsTheDefault() async {
        await Self.withStoredChoice(nil) {
            UserDefaults.standard.set("RetiredIcon", forKey: "appIcon")
            #expect(Defaults[.appIcon] == nil)
            UserDefaults.standard.set("TigerDuck", forKey: "appIcon")
            #expect(Defaults[.appIcon] == .tigerDuck)
        }
    }
}
#endif
