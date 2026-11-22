#if os(iOS)
import SwiftUI
import Testing
import TigerDuckCore
import UIKit
import WidgetKit
@testable import TigerDuck

/// The test host runs in English (`-testLanguage en`), so Chinese words on screen can only come from
/// the tag the app wrote to the App Group.
@MainActor
@Suite(.serialized)
struct WidgetAppLanguageTests {
    private typealias Fixtures = WidgetFixtures
    private typealias Host = WidgetLayoutTests.Host

    private static let zh = Locale(identifier: "zh-Hant")

    private static func zhHant(_ key: String) throws -> String {
        let path = try #require(Bundle.main.path(forResource: "zh-Hant", ofType: "lproj"))
        let value = try #require(Bundle(path: path)).localizedString(forKey: key, value: nil, table: nil)
        #expect(value != String(localized: String.LocalizationValue(key)), "\(key) reads the same in the test host's language")
        return value
    }

    private static func written(_ tag: String?) -> AppLanguage {
        let suite = "WidgetAppLanguageTests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        WidgetSnapshotStore(appGroupIdentifier: suite).language.write(AppLanguage(tag: tag))
        return AppLanguageStore(defaults: UserDefaults(suiteName: suite)).read()
    }

    private static func showLiveActivity(_ scenario: LiveActivityScenarioKind, in language: AppLanguage) throws -> UIWindow {
        let now = Date()
        let snapshot = LiveActivitySnapshot(
            scenario: scenario, title: "資料結構與演算法", subtitle: TimeRange.liveActivitySubtitle("10:20", "12:10"),
            locationText: "TR-412", instructor: "王大明", countdownTarget: now.addingTimeInterval(40 * 60),
            progressStart: now.addingTimeInterval(-10 * 60), accentHex: 0x4ECDC4, deepLink: nil, sourceId: "CS2001"
        )
        let view = LockScreenView(snapshot: snapshot, language: language)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.306, green: 0.804, blue: 0.769).opacity(0.12))
        return try Host.show(view, size: CGSize(width: 364, height: 136), background: Color(white: 0.96), margins: 0)
    }

    private static func showNextClass(_ family: WidgetFamily, at now: Date, in language: AppLanguage) throws -> UIWindow {
        let snapshot = Fixtures.snapshot()
        let derived = WidgetTimelineDerivation.derive(snapshot: snapshot, at: now)
        let upNext = WidgetTimelineDerivation.upNext(snapshot: snapshot, at: now, after: derived)
        let palette = Host.palette()
        let view = NextClassView(derived: derived, upNext: upNext, palette: palette, family: family, clock: now)
            .appLanguage(language)
        let size = family == .systemSmall ? CGSize(width: 155, height: 155) : CGSize(width: 329, height: 155)
        return try Host.show(view, size: size, background: palette.canvas, margins: family == .systemSmall ? 14 : 11)
    }

    @Test func theLiveActivityShowsTheLanguageChosenInTheApp() async throws {
        try await withAccessibilityAutomation {
            let inClass = try Self.zhHant("live_activity_status_in_class_short")
            let window = try Self.showLiveActivity(.inClass, in: Self.written("zh-Hant"))
            defer { window.isHidden = true }

            let texts = try await Host.texts(in: window, waitingFor: inClass)

            #expect(!texts.contains(String(localized: "live_activity_status_in_class_short")), "\(texts)")
            #expect(texts.contains(TimeRange.spoken("10:20", "12:10") { AppLanguage(tag: "zh-Hant").string($0) }), "\(texts)")
            #expect(texts.contains { $0.wholeMatch(of: #/\d+:\d{2}/#) != nil }, "\(texts) shows no countdown")
            window.saveSnapshot(as: "widget-app-language-live-activity-zh-Hant")
        }
    }

    @Test func aClassAboutToStartSaysSoInTheLanguageChosenInTheApp() async throws {
        try await withAccessibilityAutomation {
            let window = try Self.showLiveActivity(.classPreparing, in: Self.written("zh-Hant"))
            defer { window.isHidden = true }

            _ = try await Host.texts(in: window, waitingFor: try Self.zhHant("live_activity_status_class_preparing"))
        }
    }

    @Test func withoutATagTheLiveActivityShowsTheSystemsLanguage() async throws {
        try await withAccessibilityAutomation {
            let window = try Self.showLiveActivity(.inClass, in: Self.written(nil))
            defer { window.isHidden = true }

            let texts = try await Host.texts(in: window, waitingFor: String(localized: "live_activity_status_in_class_short"))

            #expect(texts.contains(TimeRange.spoken("10:20", "12:10")), "\(texts)")
        }
    }

    @Test func aWidgetShowsTheLanguageChosenInTheApp() async throws {
        try await withAccessibilityAutomation {
            let window = try Self.showNextClass(.systemSmall, at: Fixtures.wednesday(12, 40), in: Self.written("zh-Hant"))
            defer { window.isHidden = true }

            let texts = try await Host.texts(in: window, waitingFor: try Self.zhHant("widget_next_class"))

            #expect(!texts.contains { $0.contains(String(localized: "widget_next_class")) }, "\(texts)")
        }
    }

    @Test func withoutATagAWidgetShowsTheSystemsLanguage() async throws {
        try await withAccessibilityAutomation {
            let window = try Self.showNextClass(.systemSmall, at: Fixtures.wednesday(12, 40), in: Self.written(nil))
            defer { window.isHidden = true }

            _ = try await Host.texts(in: window, waitingFor: String(localized: "widget_next_class"))
        }
    }

    @Test func theCountdownToTheNextClassIsWrittenInTheLanguageChosenInTheApp() async throws {
        try await withAccessibilityAutomation {
            let now = Fixtures.wednesday(12, 40)
            let countdown = SystemFormatStyle.DateReference(to: Fixtures.wednesday(13, 20))
            let zh = String(countdown.locale(Self.zh).format(now).characters)
            #expect(zh != String(countdown.locale(Locale(identifier: "en")).format(now).characters))
            let window = try Self.showNextClass(.systemMedium, at: now, in: Self.written("zh-Hant"))
            defer { window.isHidden = true }

            _ = try await Host.texts(in: window, waitingFor: zh)
            window.saveSnapshot(as: "widget-app-language-next-class-medium-zh-Hant")
        }
    }

    @Test func swiftUIsOwnLookupsAndTimersFollowTheLanguageTheWidgetsAreGiven() async throws {
        try await withAccessibilityAutomation {
            let view = VStack {
                Text("widget_tomorrow")
                Text(LocalizedStringResource("widget_ongoing"))
                Text(timerInterval: Date()...Date().addingTimeInterval(40 * 60), countsDown: true)
            }
            .appLanguage(AppLanguage(tag: "zh-Hant"))
            let window = try Host.show(view, size: CGSize(width: 200, height: 120))
            defer { window.isHidden = true }

            let texts = try await Host.texts(in: window, waitingFor: try Self.zhHant("widget_tomorrow"))

            #expect(texts.contains(try Self.zhHant("widget_ongoing")), "\(texts)")
            #expect(texts.contains { $0.wholeMatch(of: #/\d+:\d{2}/#) != nil }, "\(texts) shows no timer")
        }
    }
}
#endif
