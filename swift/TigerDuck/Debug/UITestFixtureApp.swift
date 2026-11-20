#if DEBUG && os(iOS)
import SwiftUI

/// What `swift/TigerDuckUITests/` open in place of the app, so the system's own touches reach the
/// class table switcher and its list without an account. Its people live in a new temporary
/// folder, so a run reads and writes nothing of the app's own.
struct UITestFixtureApp: App {
    static let classTableSwitcher = "-classTableSwitcherFixture"
    static let userName = "B11300000"

    var body: some Scene {
        WindowGroup { ClassTableSwitcherFixture() }
    }
}

private struct ClassTableSwitcherFixture: View {
    @State private var store = Self.store()
    @State private var selection = 1
    @State private var imports = 0

    var body: some View {
        TabView(selection: $selection) {
            Tab(AppFeature.home.tabBarDisplayName, systemImage: AppFeature.home.iconName, value: 0) { Color.clear }
            Tab(AppFeature.classTable.tabBarDisplayName, systemImage: AppFeature.classTable.iconName, value: 1) {
                NavigationStack {
                    ClassTableListView(store: store, userName: UITestFixtureApp.userName)
                        .safeAreaInset(edge: .bottom) {
                            Text(verbatim: "\(store.shownPerson?.nickname ?? UITestFixtureApp.userName) \(imports)")
                                .accessibilityIdentifier("shown")
                        }
                }
            }
            Tab(AppFeature.more.tabBarDisplayName, systemImage: AppFeature.more.iconName, value: 2) { Color.clear }
        }
        .background(
            ClassTableTabBarGestures(
                tabTitle: AppFeature.classTable.tabBarDisplayName,
                isShowingClassTable: selection == 1,
                store: store,
                userName: UITestFixtureApp.userName,
                showClassTable: { selection = 1 }
            )
        )
        .environment(\.requestClassTableImport) { imports += 1 }
    }

    /// Ming and Hua in the rotation, nobody in the long-press menu, and Lin in Other.
    private static func store() -> ImportedClassTableStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = ImportedClassTableStore(
            fileURL: folder.appendingPathComponent("imported_class_tables.json"), signedInStudentId: { nil }
        )
        let signIn = AccountSession.school.currentSignIn
        let people = ["Ming", "Hua", "Lin"].enumerated().compactMap { index, name in
            store.add(
                ClassTableShareCode(
                    format: .tigerDuck, studentId: "B1130000\(index + 1)", sharedAt: nil,
                    terms: [ClassTableShareCode.Term(semester: "1151", courseNos: [])]
                ),
                nickname: name, courses: [:], for: signIn
            )
        }
        if let lin = people.last { store.move(lin.id, to: .other, before: nil, for: signIn) }
        return store
    }
}
#endif
