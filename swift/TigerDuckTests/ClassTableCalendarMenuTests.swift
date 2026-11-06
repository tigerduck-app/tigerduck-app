#if os(iOS)
import SwiftUI
import Testing
import TigerDuckCore
import UIKit
@testable import TigerDuck

/// Opens the class table's ⋯ with a finger, as `PageMenuScreenTests` does, over the user's own table
/// and over someone else's.
@MainActor
@Suite(.serialized)
struct ClassTableCalendarMenuTests {
    typealias Menus = PageMenuScreenTests

    enum Table: String, CaseIterable, CustomTestStringConvertible {
        case own, other

        var testDescription: String { rawValue }

        /// The ⋯'s items in order.
        var items: [String] {
            let exports = [String(localized: "class_table_export_screenshot"), String(localized: "class_table_export_ics")]
            return switch self {
            case .own:
                [String(localized: "add_course_title"), String(localized: "class_table_subscribe_clubs"),
                 String(localized: "class_table_share"), String(localized: "class_table_import")]
                    + exports + [String(localized: "action_settings"), String(localized: "class_table_reset_title")]
            case .other:
                exports + [String(localized: "class_table_import"), String(localized: "class_table_rename_title"),
                             String(localized: "action_settings"), String(localized: "class_table_delete_user")]
            }
        }
    }

    @MainActor
    @Observable
    final class Box {
        var export = ClassTableExportState()
        var shareModel: ClassTableShareModel?
    }

    private struct Header: View {
        let viewModel: ClassTableViewModel
        @Bindable var box: Box
        let term: SchoolCalendar.Term?

        var body: some View {
            VStack {
                HStack {
                    Text(String(localized: "feature_class_table"))
                        .font(TigerDuckTheme.Typography.title)
                    Spacer()
                    ClassTableHeaderMenu(
                        viewModel: viewModel, canExportPicture: true,
                        export: $box.export, shareModel: $box.shareModel, schoolTerm: { _, _ in term }
                    )
                }
                .padding()
                Spacer()
            }
            .background(Color.backgroundPrimary)
        }
    }

    private final class Folder {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClassTableCalendarMenuTests-\(UUID().uuidString)", isDirectory: true)
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    private struct Shown {
        let model: ClassTableViewModel
        let ming: ImportedPerson?
    }

    /// The user's own two courses, or Ming's one, in the term the table opens on.
    private static func show(_ table: Table, in folder: Folder) throws -> Shown {
        let courses = CourseStore(folders: CacheFolders(root: folder.url.appending(path: "courses")))
        let people = ImportedClassTableStore(
            fileURL: folder.url.appending(path: "imported.json"), signedInStudentId: { "B11300000" }
        )
        let model = ClassTableViewModel(courses: courses, importedTables: people)
        let semester = model.currentSemester
        switch table {
        case .own:
            for course in [
                SDCourse(courseNo: "CS2001301", courseName: "資料結構", schedule: [3: ["3", "4"]], semester: semester),
                SDCourse(courseNo: "EE2005301", courseName: "電子學", schedule: [4: ["6", "7"]], semester: semester),
            ] {
                courses.apply(.addByHand(course, semester: semester), for: testSignIn)
            }
            model.reloadFromCache()
            return Shown(model: model, ming: nil)
        case .other:
            let calculus = SDCourse(courseNo: "MA1010001", courseName: "微積分", schedule: [2: ["1", "2"]], semester: semester)
            let ming = try #require(people.add(
                ClassTableShareCode(format: .tigerDuck, studentId: "B11300001", sharedAt: nil, terms: [
                    ClassTableShareCode.Term(semester: semester, courseNos: ["MA1010001"]),
                ]),
                nickname: "Ming", courses: [semester: [calculus]], for: testSignIn
            ))
            people.show(ming.id)
            model.showShownTable()
            return Shown(model: model, ming: ming)
        }
    }

    private static func term(_ code: String) -> SchoolCalendar.Term {
        let days = ClassTableCalendarFileTests.days
        return SchoolCalendar.Term(code: code, days: days, quietDays: QuietDayCalendar(terms: [days], holidays: []))
    }

    private static func window(_ shown: Shown, box: Box, term: SchoolCalendar.Term?, look: Menus.Look) throws -> UIWindow {
        let header = Header(viewModel: shown.model, box: box, term: term)
        let (window, _) = try SettingsScreen.show(
            header, state: SettingsScreen.closed, width: Menus.narrowestPhoneWidth, height: 812, style: look.style
        )
        window.traitOverrides.preferredContentSizeCategory = look.size
        window.makeKey()
        return window
    }

    private static let menuLabel = String(localized: "class_table_more_actions")
    private static let exportItem = String(localized: "class_table_export_ics")

    @Test("Export ICS sits beside Export screenshot and hands the share sheet the shown table's file",
          arguments: Table.allCases)
    func downloadsTheShownTable(table: Table) async throws {
        try await withAccessibilityAutomation {
            let folder = Folder()
            let shown = try Self.show(table, in: folder)
            let box = Box()
            let window = try Self.window(shown, box: box, term: Self.term(shown.model.currentSemester), look: Menus.Look.all[0])
            defer { window.isHidden = true }

            let items = try await Menus.openMenu(labeled: Self.menuLabel, in: window)
            #expect(items.compactMap(\.accessibilityLabel) == table.items)
            let item = try #require(items.first { $0.accessibilityLabel == Self.exportItem })
            #expect(!item.accessibilityTraits.contains(.notEnabled))

            try await Menus.tap(item, in: window)
            try await waitUntil { box.export.file != nil }
            let url = try #require(box.export.file?.url)
            defer { ClassTableExporter.discard(url) }
            #expect(url.lastPathComponent == ClassTableExporter.fileName(
                title: String(localized: "feature_class_table"),
                semesterLabel: shown.model.displayLabel(for: shown.model.currentSemester),
                studentId: shown.ming?.nickname, pathExtension: "ics"
            ))
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text.hasPrefix("BEGIN:VCALENDAR\r\nVERSION:2.0\r\n"))
            let summaries = text.components(separatedBy: "\r\n").filter { $0.hasPrefix("SUMMARY:") }.sorted()
            if let ming = shown.ming {
                #expect(summaries == ["SUMMARY:微積分"])
                #expect(text.contains("-\(ming.id.uuidString)@tigerduck.app\r\n"))
            } else {
                #expect(summaries == ["SUMMARY:資料結構", "SUMMARY:電子學"])
            }
        }
    }

    @Test("without the academic calendar's dates for the term, Export ICS shows but is off")
    func offWithoutTheTerm() async throws {
        try await withAccessibilityAutomation {
            let folder = Folder()
            let window = try Self.window(try Self.show(.own, in: folder), box: Box(), term: nil, look: Menus.Look.all[0])
            defer { window.isHidden = true }

            let items = try await Menus.openMenu(labeled: Self.menuLabel, in: window)
            let item = try #require(items.first { $0.accessibilityLabel == Self.exportItem })
            #expect(item.accessibilityTraits.contains(.notEnabled))
        }
    }

    @Test("the ⋯ with Export ICS, open at 375 points, and scrolled to the item where the menu scrolls",
          arguments: Table.allCases, Menus.Look.all)
    func openMenuPicture(table: Table, look: Menus.Look) async throws {
        try await withAccessibilityAutomation {
            let folder = Folder()
            let shown = try Self.show(table, in: folder)
            let window = try Self.window(shown, box: Box(), term: Self.term(shown.model.currentSemester), look: look)
            defer { window.isHidden = true }

            let items = try await Menus.openMenu(labeled: Self.menuLabel, in: window)
            #expect(items.allSatisfy { $0.accessibilityFrame.maxX <= window.frame.maxX + 0.5 })
            window.saveSnapshot(as: "class-table-ics-\(table)-\(look.name)-\(Menus.language)")

            // At the largest text the list scrolls. Rows it has not shown yet have estimated heights,
            // so it scrolls by index path, twice, the second time over the rows it has laid out.
            guard let row = accessibilityElement(labeled: Self.exportItem, in: window) as? UIView,
                  let cell = Self.ancestor(of: row, as: UICollectionViewCell.self),
                  let list = Self.ancestor(of: cell, as: UICollectionView.self),
                  let indexPath = list.indexPath(for: cell), list.contentSize.height > list.bounds.height else { return }
            for _ in 0..<2 {
                list.scrollToItem(at: indexPath, at: .top, animated: false)
                list.layoutIfNeeded()
            }
            try await Task.sleep(for: .milliseconds(400))
            window.saveSnapshot(as: "class-table-ics-\(table)-\(look.name)-scrolled-\(Menus.language)")
        }
    }

    private static func ancestor<View: UIView>(of view: UIView, as type: View.Type) -> View? {
        sequence(first: view, next: \.superview).lazy.compactMap { $0 as? View }.first
    }
}
#endif
