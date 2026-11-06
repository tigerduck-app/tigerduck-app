import Foundation
import Testing
@testable import TigerDuck

struct SettingsCatalogTests {
    static let everyRowShown = SettingsState(
        library: .init(isSignedIn: true), usesEnglishClassroomNames: true,
        hasFlipToLibrary: true, hasSchoolMail: true, hasWhatsNew: true, hasMoodleApp: true
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
            let found = SettingsSearch.results(for: row.label, in: Self.everyRowShown).map(\.row)
            #expect(found.contains(row), "\(row) is not found by its own title")
        }
    }

    @Test("a row its condition hides is not listed")
    func hiddenRowsAreNotListed() {
        var chinese = Self.everyRowShown
        chinese.isChineseUI = true
        for row in [SettingsRow.englishCourseNames, .englishClassroomNames, .mandarinClassroomNames] {
            #expect(!Self.found(row, in: chinese))
        }
        var noClassroomNames = Self.everyRowShown
        noClassroomNames.usesEnglishClassroomNames = false
        #expect(!Self.found(.mandarinClassroomNames, in: noClassroomNames))
        #expect(Self.found(.englishClassroomNames, in: noClassroomNames))

        let bare = SettingsState()
        for row in [SettingsRow.flipToLibrary, .librarySignOut, .mailNotifications, .mailAccount, .whatsNew, .moodleOpenIn] {
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

    @Test("a page's ⋯ shows while one of its settings can be changed")
    func aPageMenuNeedsAnOpenRow() {
        let closed = SettingsState(hasFlipToLibrary: true, hasSchoolMail: true)
        #expect(!PageSettings.bulletins.hasMenu(in: closed))
        #expect(!PageSettings.library.hasMenu(in: closed))
        #expect(PageSettings.home.hasMenu(in: closed))
        #expect(PageSettings.mail.hasMenu(in: closed))
        var signedIn = closed
        signedIn.school.isSignedIn = true
        #expect(PageSettings.bulletins.hasMenu(in: signedIn))
    }

    @Test("matching ignores case and width, and takes words from the page name and the title")
    func matchingIgnoresCaseAndWidth() throws {
        let label = SettingsRow.showClassroom.label
        #expect(Self.found(.showClassroom, query: label.uppercased()))
        #expect(Self.found(.showClassroom, query: label.lowercased()))
        let latinLetters = SettingsRow.tigerSync.label
        let wide = try #require(latinLetters.applyingTransform(.fullwidthToHalfwidth, reverse: true))
        #expect(wide != latinLetters)
        #expect(Self.found(.tigerSync, query: wide))

        let page = String(localized: PageSettings.classTable.titleKey)
        let pageRows = SettingsSearch.results(for: page, in: Self.everyRowShown).map(\.row)
        #expect(Set(PageSettings.classTable.rows).isSubset(of: Set(pageRows)))
        #expect(SettingsSearch.results(for: "   ", in: Self.everyRowShown).isEmpty)
        #expect(SettingsSearch.results(for: "\(page) zzzz-no-such-setting", in: Self.everyRowShown).isEmpty)
    }

    @Test("a result is named by its page and its title")
    func aResultReadsPageThenTitle() throws {
        let result = try #require(SettingsSearch.results(for: SettingsRow.showClassroom.label, in: Self.everyRowShown)
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
        SettingsSearch.results(for: query, in: everyRowShown).contains { $0.row == row }
    }
}
