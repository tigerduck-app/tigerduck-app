import SwiftUI

enum ClassTableSwitcherEntry: Equatable, Identifiable {
    case importClassTable
    case person(id: UUID, nickname: String, isShown: Bool)
    case user(name: String, isShown: Bool)
    case others([ClassTableSwitcherEntry])

    static func sections(in store: ImportedClassTableStore, userName: String) -> [[ClassTableSwitcherEntry]] {
        func people(_ placement: ImportedPerson.Placement) -> [ClassTableSwitcherEntry] {
            store.people.filter { $0.placement == placement }.map {
                .person(id: $0.id, nickname: $0.nickname, isShown: $0.id == store.shownPersonID)
            }
        }
        let others = people(.other)
        return [
            [.importClassTable],
            [.user(name: userName, isShown: store.shownPersonID == nil)] + people(.rotation),
            people(.longPressMenu),
            others.isEmpty ? [] : [.others(others)],
        ]
        .filter { !$0.isEmpty }
    }

    static func userName(studentId: String?) -> String {
        guard let studentId, !studentId.isEmpty else { return String(localized: "common_not_signed_in") }
        return studentId
    }

    var id: String {
        switch self {
        case .importClassTable: "import"
        case .person(let id, _, _): id.uuidString
        case .user: "user"
        case .others: "others"
        }
    }

    var title: String {
        switch self {
        case .importClassTable: String(localized: "class_table_import")
        case .person(_, let nickname, _): nickname
        case .user(let name, _): name
        case .others: String(localized: ImportedPerson.Placement.other.titleKey)
        }
    }

    var isShown: Bool {
        switch self {
        case .importClassTable, .others: false
        case .person(_, _, let isShown), .user(_, let isShown): isShown
        }
    }

    func choose(in store: ImportedClassTableStore, requestImport: () -> Void) {
        switch self {
        case .importClassTable:
            requestImport()
        case .person(let id, _, _):
            store.show(id)
        case .user:
            store.show(nil)
        case .others:
            break
        }
    }
}

extension ImportedPerson.Placement {
    var titleKey: LocalizedStringResource {
        switch self {
        case .rotation: "class_table_list_section_double_tap"
        case .longPressMenu: "class_table_list_section_long_press"
        case .other: "class_table_list_section_other"
        }
    }
}

extension EnvironmentValues {
    @Entry var requestClassTableImport: () -> Void = {}
    /// A link's update of someone imported runs with no screen of its own, so the switcher shows it.
    @Entry var isUpdatingImportedClassTable = false
}

enum ClassTableOtherPersonAction: Hashable {
    case exportScreenshot
    case exportCalendar
    case importClassTable
    case rename
    case deleteUser

    static let sections: [[ClassTableOtherPersonAction]] = [
        [.exportScreenshot, .exportCalendar],
        [.importClassTable],
        [.rename, .deleteUser],
    ]

    var title: String {
        switch self {
        case .exportScreenshot: String(localized: "class_table_export_screenshot")
        case .exportCalendar: String(localized: "class_table_export_ics")
        case .importClassTable: String(localized: "class_table_import")
        case .rename: String(localized: "class_table_rename_title")
        case .deleteUser: String(localized: "class_table_delete_user")
        }
    }

    var systemImage: String {
        switch self {
        case .exportScreenshot: "square.and.arrow.up"
        case .exportCalendar: "calendar"
        case .importClassTable: "qrcode.viewfinder"
        case .rename: "pencil"
        case .deleteUser: "trash"
        }
    }

    var role: ButtonRole? {
        self == .deleteUser ? .destructive : nil
    }
}

struct ClassTableSwitcherMenuItems: View {
    let store: ImportedClassTableStore
    let userName: String

    @Environment(\.requestClassTableImport) private var requestImport

    var body: some View {
        ForEach(ClassTableSwitcherEntry.sections(in: store, userName: userName), id: \.first?.id) { section in
            Section {
                ForEach(section) { entry in
                    switch entry {
                    case .importClassTable:
                        Button {
                            entry.choose(in: store, requestImport: requestImport)
                        } label: {
                            Label(entry.title, systemImage: "plus")
                        }
                    case .others(let people):
                        Menu(entry.title) {
                            ForEach(people, content: toggle)
                        }
                    case .person, .user:
                        toggle(entry)
                    }
                }
            }
        }
    }

    private func toggle(_ entry: ClassTableSwitcherEntry) -> some View {
        Toggle(entry.title, isOn: Binding(
            get: { entry.isShown },
            set: { _ in entry.choose(in: store, requestImport: requestImport) }
        ))
    }
}

extension View {
    @ViewBuilder
    func courseEditMenu(isEditable: Bool, @ViewBuilder items: () -> some View) -> some View {
        if isEditable {
            contextMenu(menuItems: items)
        } else {
            self
        }
    }
}
