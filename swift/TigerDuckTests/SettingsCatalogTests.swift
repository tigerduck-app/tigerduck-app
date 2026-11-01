import Foundation
import Testing
@testable import TigerDuck

struct SettingsCatalogTests {
    /// Every row shown: a gate closed or open does not hide a row.
    static let everything = SettingsState(
        library: .init(isSignedIn: true), usesEnglishClassroomNames: true,
        hasFlipToLibrary: true, hasSchoolMail: true, hasWhatsNew: true
    )

    @Test("every row has a translated title and every page has a row")
    func everyRowHasATitleAndAPlace() {
        for row in SettingsRow.allCases {
            #expect(row.label != String(describing: row.titleKey.key), "\(row) has no translation")
        }
        for page in PageSettings.allCases {
            #expect(!page.rows.isEmpty, "\(page) lists no row")
        }
    }

    @Test("with every row shown, a search for a row's title finds it")
    func eachRowIsFoundByItsTitle() {
        for row in SettingsRow.allCases {
            let found = SettingsSearch.results(for: row.label, in: Self.everything).map(\.row)
            #expect(found.contains(row), "\(row) is not found by its own title")
        }
    }

    @Test("a row its condition hides is not listed")
    func hiddenRowsAreNotListed() {
        var chinese = Self.everything
        chinese.isChineseUI = true
        for row in [SettingsRow.englishCourseNames, .englishClassroomNames, .mandarinClassroomNames] {
            #expect(!Self.found(row, in: chinese))
        }
        var noClassroomNames = Self.everything
        noClassroomNames.usesEnglishClassroomNames = false
        #expect(!Self.found(.mandarinClassroomNames, in: noClassroomNames))
        #expect(Self.found(.englishClassroomNames, in: noClassroomNames))

        let bare = SettingsState()
        for row in [SettingsRow.flipToLibrary, .librarySignOut, .mailNotifications, .mailAccount, .whatsNew] {
            #expect(!Self.found(row, in: bare))
        }
        #expect(!PageSettings.library.isShown(in: bare))
        #expect(!PageSettings.mail.isShown(in: bare))
        #expect(PageSettings.home.isShown(in: bare))
    }

    @Test("a row its gate closes is still listed")
    func disabledRowsAreListed() {
        let closed = SettingsState(hasFlipToLibrary: true, hasSchoolMail: true)
        for row in SettingsRow.allCases where row.gate != nil {
            #expect(row.closedReason(in: closed) != nil)
            #expect(Self.found(row, in: closed), "\(row) is missing while its gate is closed")
        }
    }

    @Test("matching ignores case and width, and takes words from the page name and the title")
    func matchingIgnoresCaseAndWidth() throws {
        let label = SettingsRow.showClassroom.label
        #expect(Self.found(.showClassroom, query: label.uppercased()))
        #expect(Self.found(.showClassroom, query: label.lowercased()))
        // TigerSync is spelled in Latin letters in every language, so it has a full-width form.
        let sync = SettingsRow.tigerSync.label
        let wide = try #require(sync.applyingTransform(.fullwidthToHalfwidth, reverse: true))
        #expect(wide != sync)
        #expect(Self.found(.tigerSync, query: wide))

        let page = String(localized: PageSettings.classTable.titleKey)
        let pageRows = SettingsSearch.results(for: page, in: Self.everything).map(\.row)
        #expect(Set(PageSettings.classTable.rows).isSubset(of: Set(pageRows)))
        #expect(SettingsSearch.results(for: "   ", in: Self.everything).isEmpty)
        #expect(SettingsSearch.results(for: "\(page) zzzz-no-such-setting", in: Self.everything).isEmpty)
    }

    @Test("a result is named by its page and its title")
    func aResultReadsPageThenTitle() throws {
        let result = try #require(SettingsSearch.results(for: SettingsRow.showClassroom.label, in: Self.everything)
            .first { $0.row == .showClassroom })
        #expect(result.text == "\(String(localized: PageSettings.classTable.titleKey)) › \(SettingsRow.showClassroom.label)")
        #expect(SettingsSearch.path(of: .tigerSync) == [SettingsRow.tigerSync.label])
        #expect(SettingsSearch.path(of: .notificationPermissions) == [SettingsRow.notificationPermissions.label])
    }

    @Test("each gate opens on its own condition")
    func eachGateOpensOnItsCondition() {
        let closed = SettingsState()
        #expect(SettingsGate.tigerSync.isOpen(in: SettingsState(isCloudSyncOn: true)))
        #expect(SettingsGate.schoolSignIn.isOpen(in: SettingsState(school: .init(isSignedIn: true))))
        #expect(SettingsGate.mailSignIn.isOpen(in: SettingsState(mail: .init(isSignedIn: true))))
        #expect(SettingsGate.librarySignIn.isOpen(in: SettingsState(library: .init(isSignedIn: true))))
        for gate in [SettingsGate.tigerSync, .schoolSignIn, .mailSignIn, .librarySignIn] {
            #expect(!gate.isOpen(in: closed))
        }
    }

    private static func found(_ row: SettingsRow, in state: SettingsState) -> Bool {
        SettingsSearch.results(for: row.label, in: state).contains { $0.row == row }
    }

    private static func found(_ row: SettingsRow, query: String) -> Bool {
        SettingsSearch.results(for: query, in: everything).contains { $0.row == row }
    }
}
