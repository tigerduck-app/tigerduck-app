#if os(iOS)
import Defaults
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct AppIconSettingsScreenTests {
    private typealias Screen = SettingsScreen

    private static var labels: [String] { AppIcon.choices.map { String(localized: AppIcon.titleKey(of: $0)) } }

    private static func withStoredChoice(_ stored: AppIcon?, _ body: () async throws -> Void) async throws {
        try await withAccessibilityAutomation {
            try await withExclusiveRealDefaults {
                let saved = Defaults[.appIcon]
                defer { Defaults[.appIcon] = saved }
                Defaults[.appIcon] = stored
                try await body()
            }
        }
    }

    private static func cells(in host: UIViewController) -> [NSObject] {
        labels.compactMap { label in Screen.elements(in: host).first { $0.accessibilityLabel == label } }
    }

    @Test("Settings lists App Icon above API endpoint, with the chosen icon's name as its value",
          arguments: [AppIcon?.none, .tigerDuckChristmas])
    func theSettingsRow(stored: AppIcon?) async throws {
        try await Self.withStoredChoice(stored) {
            let (window, host) = try Screen.show(SettingsList(sheets: SettingsSheetState()), state: Screen.closed, height: 4000)
            defer { window.isHidden = true }
            let value = String(localized: AppIcon.titleKey(of: stored))
            try await waitUntil {
                Screen.element(of: .appIcon, hint: nil, in: host) != nil && Screen.element(of: .apiEndpoint, hint: nil, in: host) != nil
            }
            let row = try #require(Screen.element(of: .appIcon, hint: nil, in: host))
            let endpoint = try #require(Screen.element(of: .apiEndpoint, hint: nil, in: host))

            #expect([row.accessibilityLabel, row.accessibilityValue].compactMap { $0 }.joined(separator: ", ").contains(value))
            #expect(row.accessibilityTraits.contains(.button))
            #expect(row.accessibilityFrame.maxY <= endpoint.accessibilityFrame.minY + 0.5)
            let above = Screen.elements(in: host).filter {
                $0.accessibilityFrame.minY < endpoint.accessibilityFrame.minY && $0.accessibilityFrame.minY > row.accessibilityFrame.minY
            }
            #expect(above.isEmpty, "a row sits between App Icon and API endpoint")
        }
    }

    @Test("the row opens the App Icon page")
    func theRowOpensThePage() async throws {
        try await Self.withStoredChoice(nil) {
            let (window, host) = try Screen.show(SettingsList(sheets: SettingsSheetState()), state: Screen.closed, height: 4000)
            defer { window.isHidden = true }
            try await waitUntil { Screen.element(of: .appIcon, hint: nil, in: host) != nil }

            _ = try #require(Screen.element(of: .appIcon, hint: nil, in: host)).accessibilityActivate()

            try await waitUntil { Screen.depth(in: host) == 2 }
            #expect(Screen.navigation(in: host)?.topViewController?.navigationItem.title == SettingsRow.appIcon.label)
        }
    }

    @Test("the page puts three icons on a row, each a button with its name, and marks only the chosen one",
          arguments: SettingsSnapshotTests.widths)
    func theGrid(width: CGFloat) async throws {
        try await Self.withStoredChoice(.tigerDuck) {
            let (window, host) = try Screen.show(
                AppIconSettingsView(host: FakeAlternateIconHost(showing: "TigerDuck")), state: Screen.closed, width: width, height: 874
            )
            defer { window.isHidden = true }
            try await waitUntil { Self.cells(in: host).count == Self.labels.count }
            let cells = Self.cells(in: host)
            let frames = cells.map(\.accessibilityFrame)

            let columns = AppIconSettingsView.columnCount
            for (index, frame) in frames.enumerated() {
                #expect(abs(frame.minY - frames[index / columns * columns].minY) < 0.5, "cell \(index) is off its row")
                #expect(abs(frame.minX - frames[index % columns].minX) < 0.5, "cell \(index) is off its column")
            }
            #expect(frames[1].minX > frames[0].maxX && frames[2].minX > frames[1].maxX)
            #expect(frames[columns].minY > frames[0].maxY)
            #expect(frames.allSatisfy { $0.minX >= 0 && $0.maxX <= window.bounds.maxX + 0.5 })
            for (cell, icon) in zip(cells, AppIcon.choices) {
                #expect(cell.accessibilityTraits.contains(.button))
                #expect(cell.accessibilityTraits.contains(.selected) == (icon == .tigerDuck), "\(String(describing: icon))")
            }
        }
    }

    @Test("tapping a cell applies its icon and moves the mark to it")
    func tappingACellAppliesIt() async throws {
        try await Self.withStoredChoice(nil) {
            let host = FakeAlternateIconHost()
            let (window, hosting) = try Screen.show(AppIconSettingsView(host: host), state: Screen.closed, height: 874)
            defer { window.isHidden = true }
            let christmas = String(localized: AppIcon.tigerDuckChristmas.titleKey)
            @MainActor func cell(_ label: String) -> NSObject? { Screen.elements(in: hosting).first { $0.accessibilityLabel == label } }
            try await waitUntil { cell(christmas) != nil }

            _ = try #require(cell(christmas)).accessibilityActivate()

            try await waitUntil { cell(christmas)?.accessibilityTraits.contains(.selected) == true }
            #expect(host.requests == ["TigerDuckChristmas"])
            #expect(Defaults[.appIcon] == .tigerDuckChristmas)
            #expect(cell(Self.labels[0])?.accessibilityTraits.contains(.selected) == false)
        }
    }

    @Test("the App Icon page", arguments: ClubScreensTests.looks, SettingsSnapshotTests.widths)
    func snapshot(look: ClubScreensTests.Look, width: CGFloat) async throws {
        try await Self.withStoredChoice(nil) {
            let (window, host) = try Screen.show(
                AppIconSettingsView(host: FakeAlternateIconHost()), state: Screen.closed, width: width, height: 874, style: look.style
            )
            defer { window.isHidden = true }
            window.traitOverrides.preferredContentSizeCategory = look.textSize
            try await waitUntil { Self.cells(in: host).count == Self.labels.count }
            try await Task.sleep(for: .milliseconds(400))
            let frames = Self.cells(in: host).map(\.accessibilityFrame)
            #expect(frames.allSatisfy { $0.minX >= 0 && $0.maxX <= window.bounds.maxX + 0.5 }, "a cell is wider than the phone")
            #expect(Set(frames.map { $0.height.rounded() }).count == 1, "a name takes more lines than another")
            let language = Bundle.main.preferredLocalizations.first ?? "en"
            window.saveSnapshot(as: "app-icon-\(look.testDescription)-\(Int(width))-\(language)")
        }
    }
}
#endif
