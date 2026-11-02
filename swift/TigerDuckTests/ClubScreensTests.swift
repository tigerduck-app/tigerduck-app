#if os(iOS)
import SwiftUI
import Testing
import TigerDuckCore
import UIKit
@testable import TigerDuck

/// The club screens of the class table at the narrowest phone, light and dark, and at the largest
/// text size. A local run on the build host also saves each one to `.out/club-ui`.
@MainActor
@Suite(.serialized)
struct ClubScreensTests {
    struct Look: CustomTestStringConvertible {
        let style: UIUserInterfaceStyle
        let textSize: UIContentSizeCategory

        var testDescription: String {
            "\(style == .dark ? "dark" : "light")-\(textSize == .large ? "default" : "largest")"
        }
    }

    static let looks = [
        Look(style: .light, textSize: .large),
        Look(style: .dark, textSize: .large),
        Look(style: .light, textSize: .accessibilityExtraExtraExtraLarge),
    ]

    static let width: CGFloat = 375
    static let monday = Date(timeIntervalSince1970: 1_793_548_800)
    static let dates = (0..<7).map { monday.addingTimeInterval(Double($0) * 86_400) }

    static func show(_ view: some View, look: Look, height: CGFloat = 812) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.overrideUserInterfaceStyle = look.style
        window.traitOverrides.preferredContentSizeCategory = look.textSize
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        return window
    }

    static func shows(_ text: String, in window: UIWindow) -> Bool {
        exposedAccessibilityTexts(in: window).contains { $0.contains(text) }
    }

    static func save(_ window: UIWindow, as name: String, file: String = #filePath) {
        let out = URL(filePath: file).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: ".out/club-ui")
        // CI's checkout has no `.out` folder, so only a local run keeps the picture.
        guard FileManager.default.fileExists(atPath: out.deletingLastPathComponent().path(percentEncoded: false)) else { return }
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try? image.pngData()?.write(to: out.appending(path: "\(name)-\(language).png"))
    }

    @Test("the subscribe sheet lists the subscribed clubs by rank, then every club", arguments: looks)
    func subscribeSheet(look: Look) async throws {
        try await withExclusiveRealDefaults {
            try await withAccessibilityAutomation {
                let stores = try ClubMock.stores(dates: Self.dates)
                defer { ClubMock.reset(stores) }
                let sheet = ClubSubscribeSheet(signIn: testSignIn, directory: stores.directory, subscriptions: stores.subscriptions)
                let window = try Self.show(sheet, look: look)
                defer { window.isHidden = true }
                let first = String(format: String(localized: "a11y_class_table_club_color"), ClubMock.clubs[0].zh)
                try await waitUntil { accessibilityElement(labeled: first, in: window) != nil }
                try await Task.sleep(for: .milliseconds(400))
                Self.save(window, as: "subscribe-\(look.testDescription)")

                let ranks = Dictionary(uniqueKeysWithValues: ClubMock.clubs.enumerated().map { rank, club in
                    (String(format: String(localized: "a11y_class_table_club_color"), club.zh), rank)
                })
                var seen = Set<Int>()
                let shown = exposedAccessibilityLabels(in: window).compactMap { ranks[$0] }.filter { seen.insert($0).inserted }
                #expect(!shown.isEmpty)
                #expect(shown == shown.sorted())
            }
        }
    }

    @Test("a club's mark in the list subscribes it, only for the sign-in the sheet opened in", arguments: [false, true])
    func subscribeToggle(signedOut: Bool) async throws {
        try await withExclusiveRealDefaults {
            try await withAccessibilityAutomation {
                let stores = try ClubMock.stores(dates: Self.dates)
                defer { ClubMock.reset(stores) }
                stores.subscriptions.unsubscribe(106, for: testSignIn)
                let sheet = ClubSubscribeSheet(
                    signIn: signedOut ? endedTestSignIn : testSignIn, directory: stores.directory, subscriptions: stores.subscriptions
                )
                let window = try Self.show(sheet, look: Self.looks[0], height: 2400)
                defer { window.isHidden = true }
                let name = ClubMock.clubs[5].zh
                let hint = String(localized: "class_table_club_subscribe_action")
                let row = { @MainActor in
                    exposedAccessibilityElements(in: window).first { $0.accessibilityLabel?.contains(name) == true }
                }
                try await waitUntil { row()?.accessibilityHint == hint }

                _ = row()?.accessibilityActivate()
                #expect(stores.subscriptions.isSubscribed(106) == !signedOut)
                #expect(stores.subscriptions.subscribedIDs.last == (signedOut ? 105 : 106))
            }
        }
    }

    @Test("an activity's details: the club, the activity, where, when and what kind", arguments: looks)
    func detail(look: Look) async throws {
        try await withAccessibilityAutomation {
            let club = try #require(ClubMock.occurrences(on: 1).first)
            let window = try Self.show(ClubActivityDetailSheet(club: club, policy: AppPreferences().visualStylePolicy), look: look)
            defer { window.isHidden = true }
            try await waitUntil { Self.shows(club.content, in: window) }
            try await Task.sleep(for: .milliseconds(400))
            Self.save(window, as: "detail-\(look.testDescription)")

            for text in [club.clubName, club.name, club.location, "19:00 - 21:00", String(localized: "class_table_club_activity_type_meeting")] {
                #expect(Self.shows(text, in: window), "\(text)")
            }
        }
    }

    @Test("the picker of activities that meet lists them by rank", arguments: looks)
    func picker(look: Look) async throws {
        try await withAccessibilityAutomation {
            let clubs = ClubMock.occurrences(on: 1)
            var picked: String?
            let sheet = ConflictPickerSheet(
                title: String(localized: "class_table_club_picker_title"),
                rows: clubs.map(ConflictPickerSheet.Row.init(club:)),
                onPick: { picked = $0 }
            )
            let window = try Self.show(sheet, look: look)
            defer { window.isHidden = true }
            try await waitUntil { Self.shows(clubs[1].clubName, in: window) }
            try await Task.sleep(for: .milliseconds(400))
            Self.save(window, as: "picker-\(look.testDescription)")

            let row = try #require(exposedAccessibilityElements(in: window).first {
                $0.accessibilityLabel?.contains(clubs[1].clubName) == true
            })
            #expect(row.accessibilityLabel?.contains("19:00 - 21:30 · 學生活動中心 B1") == true)
            _ = row.accessibilityActivate()
            #expect(picked == String(clubs[1].id))
        }
    }

    @Test("a club's color sheet shows its name alone and saves the pick for its sign-in", arguments: looks)
    func colorSheet(look: Look) async throws {
        try await withExclusiveRealDefaults {
            try await withAccessibilityAutomation {
                let stores = try ClubMock.stores(dates: Self.dates)
                defer { ClubMock.reset(stores) }
                let club = ClubMock.clubs[0]
                let target = ClassTableEditor.ClubColorTarget(id: club.id, name: club.zh)
                let window = try Self.show(
                    Color.clear.clubColorSheet(.constant(target), signIn: testSignIn, subscriptions: stores.subscriptions),
                    look: look
                )
                defer {
                    window.rootViewController?.dismiss(animated: false)
                    window.isHidden = true
                }
                let swatch = String(format: String(localized: "a11y_class_table_club_color_swatch"), 1)
                try await waitUntil { accessibilityElement(labeled: swatch, in: window) != nil }
                try await Task.sleep(for: .milliseconds(600))
                Self.save(window, as: "color-\(look.testDescription)")

                #expect(stores.subscriptions.color(of: club.id) != TigerDuckTheme.coursePaletteHexes[0])
                _ = accessibilityElement(labeled: swatch, in: window)?.accessibilityActivate()
                #expect(stores.subscriptions.color(of: club.id) == TigerDuckTheme.coursePaletteHexes[0])
            }
        }
    }

    @Test("a tap on activities that meet opens the picker; on one alone, its details")
    func gridTaps() async throws {
        try await withExclusiveRealDefaults {
            try await withAccessibilityAutomation {
                let stores = try ClubMock.stores(dates: Self.dates)
                defer { ClubMock.reset(stores) }
                let root = FileManager.default.temporaryDirectory.appending(path: "ClubGrid-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: root) }
                let model = ClassTableViewModel(
                    courses: CourseStore(folders: CacheFolders(root: root)),
                    importedTables: ImportedClassTableStore(
                        fileURL: root.appendingPathComponent("imported.json"), signedInStudentId: { nil }
                    ),
                    clubs: stores.feed
                )
                model.grid.showClubs(on: Self.dates)
                let metrics = TimetableCellMetrics(cellHeight: 52, rowSpacing: 3, courseNameSize: 10, badgeIconSize: 8)
                let periods = model.grid.activePeriods
                let layer = HStack(spacing: 3) {
                    ForEach(model.grid.activeWeekdays, id: \.self) { weekday in
                        TimetableClubColumn(
                            viewModel: model, weekday: weekday, periods: periods, metrics: metrics,
                            drawsPeriodTiles: false, policy: AppPreferences().visualStylePolicy
                        )
                    }
                }
                .frame(height: CGFloat(periods.count) * 55)
                let window = try Self.show(layer, look: Self.looks[0], height: 900)
                defer { window.isHidden = true }
                let monday = try #require(ClubMock.occurrences(on: 1).last)
                let thursday = try #require(ClubMock.occurrences(on: 4).first)
                try await waitUntil {
                    accessibilityElement(labeled: TimetableClubBlock.spoken(thursday), in: window) != nil
                }

                _ = accessibilityElement(labeled: TimetableClubBlock.spoken(monday), in: window)?.accessibilityActivate()
                #expect(model.selection.clubPicker?.clubs.map(\.id) == [1, 2])
                #expect(model.selection.club == nil)

                model.selection.clubPicker = nil
                _ = accessibilityElement(labeled: TimetableClubBlock.spoken(thursday), in: window)?.accessibilityActivate()
                #expect(model.selection.club?.id == thursday.id)

                let cut = try #require(ClubMock.occurrences(on: 3).first { $0.id == 3 })
                #expect(accessibilityElement(labeled: TimetableClubBlock.spoken(cut), in: window) != nil)
            }
        }
    }
}
#endif
