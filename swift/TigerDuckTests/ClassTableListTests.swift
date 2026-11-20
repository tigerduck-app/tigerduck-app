#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct ClassTableListTests {
    private final class Folder {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClassTableListTests-\(UUID().uuidString)", isDirectory: true)
        var file: URL { url.appendingPathComponent("imported_class_tables.json") }
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    private struct People {
        let store: ImportedClassTableStore
        let ming: UUID
        let hua: UUID
        let lin: UUID
    }

    /// Ming in the rotation, Hua in the long-press menu and Lin in Other, unless `hua` says otherwise.
    private static func people(
        _ folder: Folder, names: [String] = ["Ming", "Hua", "Lin"], hua: ImportedPerson.Placement = .longPressMenu
    ) throws -> People {
        let store = ImportedClassTableStore(fileURL: folder.file, signedInStudentId: { "B11300000" })
        let ids = try names.enumerated().map { index, name in
            let code = ClassTableShareCode(
                format: .tigerDuck, studentId: "B1130000\(index + 1)", sharedAt: nil,
                terms: [ClassTableShareCode.Term(semester: "1151", courseNos: ["CS1010001"])]
            )
            return try #require(store.add(code, nickname: name, courses: [:], for: testSignIn)).id
        }
        store.move(ids[1], to: hua, before: nil, for: testSignIn)
        store.move(ids[2], to: .other, before: nil, for: testSignIn)
        return People(store: store, ming: ids[0], hua: ids[1], lin: ids[2])
    }

    private struct Shown {
        let window: UIWindow
        let list: UICollectionView
        let rows: ClassTableListRows.Coordinator
    }

    private static func show(
        _ store: ImportedClassTableStore, look: ClubScreensTests.Look = ClubScreensTests.looks[0], width: CGFloat = 402
    ) async throws -> Shown {
        let view = NavigationStack { ClassTableListView(store: store, userName: "B11300000") }
        let window = try ClubScreensTests.show(view, look: look, width: width, height: 874)
        var list: UICollectionView?
        try await waitUntil {
            list = window.rootViewController?.view.descendants(ofType: UICollectionView.self).first
            return list?.numberOfSections == 3
        }
        let shown = try #require(list)
        return Shown(window: window, list: shown, rows: try #require(shown.delegate as? ClassTableListRows.Coordinator))
    }

    private static func counts(_ list: UICollectionView) -> [Int] {
        (0..<list.numberOfSections).map { list.numberOfItems(inSection: $0) }
    }

    private static func cell(_ list: UICollectionView, _ item: Int, _ section: Int) -> UICollectionViewListCell? {
        list.layoutIfNeeded()
        return list.cellForItem(at: IndexPath(item: item, section: section)) as? UICollectionViewListCell
    }

    private static func text(of view: UICollectionViewListCell?) -> String? {
        (view?.contentConfiguration as? UIListContentConfiguration)?.text
    }

    private static func placements(_ store: ImportedClassTableStore) -> [ImportedPerson.Placement: [String]] {
        Dictionary(grouping: store.people, by: \.placement).mapValues { $0.map(\.nickname) }
    }

    @Test("the list has the three placements in order, you first in the rotation with no handle, and a handle on everyone else")
    func sectionsAndRows() async throws {
        let people = try Self.people(Folder())
        let shown = try await Self.show(people.store)
        defer { shown.window.isHidden = true }

        #expect(Self.counts(shown.list) == [2, 1, 1])
        let headers = (0..<3).map { section in
            Self.text(of: shown.list.supplementaryView(
                forElementKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: section)
            ) as? UICollectionViewListCell)
        }
        #expect(headers == [
            String(localized: "class_table_list_section_double_tap"),
            String(localized: "class_table_list_section_long_press"),
            String(localized: "class_table_list_section_other"),
        ])
        let rows = [(0, 0), (1, 0), (0, 1), (0, 2)].map { Self.cell(shown.list, $0, $1) }
        #expect(rows.map(Self.text(of:)) == ["B11300000", "Ming", "Hua", "Lin"])
        #expect(rows.map { $0?.accessories.map(\.accessoryType) ?? [] } == [[], [.reorder], [.reorder], [.reorder]])
        let you = try #require(rows[0])
        #expect(!you.accessibilityTraits.contains(.button))
        #expect(you.accessibilityCustomActions?.isEmpty != false)
        #expect(shown.list.delegate?.collectionView?(shown.list, shouldHighlightItemAt: IndexPath(item: 0, section: 0)) == false)
        #expect(shown.rows.deleteAction(at: IndexPath(item: 0, section: 0)) == nil)
    }

    @Test("a tap on someone opens the rename dialog with their nickname")
    func tapRenames() async throws {
        let people = try Self.people(Folder())
        let shown = try await Self.show(people.store)
        defer { shown.window.isHidden = true }
        let dialogs = try #require(shown.rows.parent?.dialogs)

        shown.list.delegate?.collectionView?(shown.list, didSelectItemAt: IndexPath(item: 0, section: 2))

        #expect(dialogs.isRenamingPerson)
        #expect(dialogs.nicknameDraft == "Lin")
        dialogs.nicknameDraft = "Lin Lin"
        dialogs.saveNickname()
        #expect(people.store.people.map(\.nickname) == ["Ming", "Hua", "Lin Lin"])
    }

    @Test("a swipe on someone offers delete, which asks the existing question before deleting")
    func swipeDeletes() async throws {
        let people = try Self.people(Folder())
        let shown = try await Self.show(people.store)
        defer { shown.window.isHidden = true }

        let swipe = try #require(shown.rows.deleteAction(at: IndexPath(item: 0, section: 1)))
        let delete = try #require(swipe.actions.first)
        #expect(swipe.actions.count == 1)
        #expect(delete.backgroundColor == .systemRed)
        #expect(delete.accessibilityLabel == String(localized: "class_table_delete_user"))
        let dialogs = try #require(shown.rows.parent?.dialogs)
        delete.handler(delete, shown.list) { _ in }

        #expect(dialogs.isDeletingPerson)
        #expect(dialogs.personInAlert?.id == people.hua)
        #expect(people.store.people.count == 3)
    }

    @Test("VoiceOver moves someone to each other placement by its title, and offers the delete")
    func voiceOverActions() async throws {
        let people = try Self.people(Folder())
        let shown = try await Self.show(people.store)
        defer { shown.window.isHidden = true }
        let hua = try #require(Self.cell(shown.list, 0, 1))

        let actions = try #require(hua.accessibilityCustomActions)
        #expect(actions.map(\.name) == [
            String(localized: "class_table_list_section_double_tap"),
            String(localized: "class_table_list_section_other"),
            String(localized: "class_table_delete_user"),
        ])
        #expect(hua.accessibilityTraits.contains(.button))
        let toOther = try #require(actions.dropFirst().first)
        #expect(toOther.actionHandler?(toOther) == true)

        #expect(Self.placements(people.store) == [.rotation: ["Ming"], .other: ["Lin", "Hua"]])
        try await waitUntil { Self.counts(shown.list) == [2, 0, 2] }
        try await waitUntil {
            Self.cell(shown.list, 1, 2)?.accessibilityCustomActions?.map(\.name) == [
                String(localized: "class_table_list_section_double_tap"),
                String(localized: "class_table_list_section_long_press"),
                String(localized: "class_table_delete_user"),
            ]
        }
    }

    /// Where a dragged row would be: the middle of a row, or under a section's header.
    private static func point(of item: Int, in section: Int, list: UICollectionView) throws -> CGPoint {
        let frame = try #require(list.layoutAttributesForItem(at: IndexPath(item: item, section: section))?.frame)
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    private static func underHeader(of section: Int, list: UICollectionView) throws -> CGPoint {
        let header = try #require(list.layoutAttributesForSupplementaryElement(
            ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: section)
        )?.frame)
        return CGPoint(x: header.midX, y: header.maxY + 8)
    }

    private static func drag(_ from: IndexPath, to point: CGPoint, in list: UICollectionView) async throws {
        #expect(list.beginInteractiveMovementForItem(at: from))
        list.updateInteractiveMovementTargetPosition(point)
        try await Task.sleep(for: .milliseconds(100))
        list.endInteractiveMovement()
    }

    @Test("a drag reorders within a placement, moves between placements and into an empty one, and keeps you first")
    func dragsMovePeople() async throws {
        let folder = Folder()
        let people = try Self.people(folder, hua: .rotation)
        let shown = try await Self.show(people.store)
        defer { shown.window.isHidden = true }
        let list = shown.list
        #expect(Self.counts(list) == [3, 0, 1])

        try await Self.drag(IndexPath(item: 2, section: 0), to: try Self.underHeader(of: 1, list: list), in: list)
        try await waitUntil { Self.placements(people.store)[.longPressMenu] == ["Hua"] }
        #expect(Self.placements(people.store) == [.rotation: ["Ming"], .longPressMenu: ["Hua"], .other: ["Lin"]])

        try await Self.drag(IndexPath(item: 0, section: 2), to: try Self.point(of: 1, in: 0, list: list), in: list)
        try await waitUntil { Self.placements(people.store)[.other] == nil }
        #expect(Self.placements(people.store) == [.rotation: ["Lin", "Ming"], .longPressMenu: ["Hua"]])

        try await Self.drag(IndexPath(item: 2, section: 0), to: try Self.point(of: 0, in: 0, list: list), in: list)
        try await waitUntil { Self.placements(people.store)[.rotation] == ["Ming", "Lin"] }
        try await waitUntil { Self.counts(list) == [3, 1, 0] }
        #expect(Self.text(of: Self.cell(list, 0, 0)) == "B11300000")
        #expect(Self.text(of: Self.cell(list, 1, 0)) == "Ming")
        let saved = ImportedClassTableStore(fileURL: folder.file, signedInStudentId: { "B11300000" })
        #expect(Self.placements(saved) == [.rotation: ["Ming", "Lin"], .longPressMenu: ["Hua"]])
    }

    @Test("the list at both phone widths, in each look, with long nicknames", arguments: ClubScreensTests.looks, [CGFloat(375), 402])
    func snapshots(look: ClubScreensTests.Look, width: CGFloat) async throws {
        let names = ["Wolfeschlegelsteinhausenbergerdorff from the Club", "王小明的室友兼社團學長兼家教學生", "Lin"]
        let people = try Self.people(Folder(), names: names)
        let shown = try await Self.show(people.store, look: look, width: width)
        defer { shown.window.isHidden = true }
        try await Task.sleep(for: .milliseconds(400))
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        shown.window.saveSnapshot(as: "class-table-list-\(look.testDescription)-\(Int(width))-\(language)-\(UIDevice.current.systemVersion)")
        #expect(Self.counts(shown.list) == [2, 1, 1])
    }
}
#endif
