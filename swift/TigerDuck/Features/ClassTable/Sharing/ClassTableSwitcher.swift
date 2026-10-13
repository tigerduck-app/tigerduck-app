import SwiftUI

/// One row of the class table switcher. The tab bar's menu and the class table's top-right menu
/// both list `sections(in:userName:)`: "Import class table", the people in import order, then the
/// user's own class table under their student ID.
enum ClassTableSwitcherEntry: Equatable, Identifiable {
    case importClassTable
    case person(id: UUID, nickname: String, isShown: Bool)
    case user(name: String, isShown: Bool)

    static func sections(in store: ImportedClassTableStore, userName: String) -> [[ClassTableSwitcherEntry]] {
        let people = store.people.map {
            ClassTableSwitcherEntry.person(id: $0.id, nickname: $0.nickname, isShown: $0.id == store.shownPersonID)
        }
        return [[.importClassTable], people, [.user(name: userName, isShown: store.shownPersonID == nil)]]
            .filter { !$0.isEmpty }
    }

    /// The user's own row: their student ID, which is what the class table shows for them.
    static func userName(studentId: String?) -> String {
        guard let studentId, !studentId.isEmpty else { return String(localized: "common_not_signed_in") }
        return studentId
    }

    var id: String {
        switch self {
        case .importClassTable: "import"
        case .person(let id, _, _): id.uuidString
        case .user: "user"
        }
    }

    var title: String {
        switch self {
        case .importClassTable: String(localized: "class_table_import")
        case .person(_, let nickname, _): nickname
        case .user(let name, _): name
        }
    }

    var isShown: Bool {
        switch self {
        case .importClassTable: false
        case .person(_, _, let isShown), .user(_, let isShown): isShown
        }
    }

    func choose(in store: ImportedClassTableStore) {
        switch self {
        case .importClassTable:
            Self.requestImport()
        case .person(let id, _, _):
            store.show(id)
        case .user:
            store.show(nil)
        }
    }

    /// The import flow presents itself on `classTableImportRequested`, so the menus that offer it
    /// need no reference to it.
    static func requestImport() {
        NotificationCenter.default.post(name: AppConstants.classTableImportRequested, object: nil)
    }
}

/// The ⋯ menu of someone else's class table, which is read-only: export and import as on the
/// user's own, then what applies to the person.
enum ClassTableOtherPersonAction: Hashable {
    case exportScreenshot
    case importClassTable
    case rename
    case deleteUser

    static let sections: [[ClassTableOtherPersonAction]] = [
        [.exportScreenshot],
        [.importClassTable],
        [.rename, .deleteUser],
    ]

    var title: String {
        switch self {
        case .exportScreenshot: String(localized: "class_table_export_screenshot")
        case .importClassTable: String(localized: "class_table_import")
        case .rename: String(localized: "class_table_rename_title")
        case .deleteUser: String(localized: "class_table_delete_user")
        }
    }

    var systemImage: String {
        switch self {
        case .exportScreenshot: "square.and.arrow.up"
        case .importClassTable: "qrcode.viewfinder"
        case .rename: "pencil"
        case .deleteUser: "trash"
        }
    }

    var role: ButtonRole? {
        self == .deleteUser ? .destructive : nil
    }
}

/// The switcher's rows as the items of a SwiftUI `Menu`, a checkmark on the class table shown.
struct ClassTableSwitcherMenuItems: View {
    let store: ImportedClassTableStore
    let userName: String

    var body: some View {
        ForEach(ClassTableSwitcherEntry.sections(in: store, userName: userName), id: \.first?.id) { section in
            Section {
                ForEach(section) { entry in
                    if case .importClassTable = entry {
                        Button {
                            entry.choose(in: store)
                        } label: {
                            Label(entry.title, systemImage: "plus")
                        }
                    } else {
                        Toggle(entry.title, isOn: Binding(
                            get: { entry.isShown },
                            set: { _ in entry.choose(in: store) }
                        ))
                    }
                }
            }
        }
    }
}

extension View {
    /// A course's edit menu. Someone else's class table is read-only, so its courses get none.
    @ViewBuilder
    func courseEditMenu(isEditable: Bool, @ViewBuilder items: () -> some View) -> some View {
        if isEditable {
            contextMenu(menuItems: items)
        } else {
            self
        }
    }
}
