import Defaults
import Foundation
import Testing
@testable import TigerDuck

/// The term list refreshes while the app runs (`SemesterCatalog.refreshIfStale`), so a term
/// published mid-session has to reach the class table without a relaunch.
///
/// Serialized, and synchronous on the main actor: the tests swap the process-wide catalogue
/// cache and the stored pick, and put both back before anything else can read them.
@Suite(.serialized)
@MainActor
struct ClassTableSemesterTests {
    /// `SemesterCatalog.listKey`, which is private to the catalogue.
    private static let catalogueKey = "semesterCatalog.semesters"

    private static func withCatalogue(_ terms: [String], storedPick: String?, _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let savedTerms = defaults.stringArray(forKey: catalogueKey)
        let savedPick = Defaults[.classTableSelectedSemester]
        defer {
            defaults.set(savedTerms, forKey: catalogueKey)
            Defaults[.classTableSelectedSemester] = savedPick
        }
        defaults.set(terms, forKey: catalogueKey)
        Defaults[.classTableSelectedSemester] = storedPick
        body()
    }

    private static func publish(_ terms: [String]) {
        UserDefaults.standard.set(terms, forKey: catalogueKey)
    }

    @Test func aTermPublishedMidSessionOpensAnUnpickedTable() {
        Self.withCatalogue(["1151", "1142", "1141"], storedPick: nil) {
            let viewModel = ClassTableViewModel()
            #expect(viewModel.currentSemester == "1151")

            Self.publish(["1152", "1151", "1142", "1141"])
            viewModel.reloadFromCache()

            #expect(viewModel.availableSemesters.first == "1152")
            #expect(viewModel.currentSemester == "1152")
            // Following the newest term is not a pick, or the table would freeze on it.
            #expect(Defaults[.classTableSelectedSemester] == nil)
        }
    }

    @Test func aPickedTermStaysWhenANewerOneIsPublished() {
        Self.withCatalogue(["1151", "1142", "1141"], storedPick: "1142") {
            let viewModel = ClassTableViewModel()
            #expect(viewModel.currentSemester == "1142")

            Self.publish(["1152", "1151", "1142", "1141"])
            viewModel.reloadFromCache()

            #expect(viewModel.availableSemesters.contains("1152"))
            #expect(viewModel.currentSemester == "1142")
        }
    }

    @Test func aClearedPickFollowsTheNewestTermOnTheNextReload() {
        // Sign-out clears the stored pick, then posts `dataDidUpdate`, which reloads the table.
        Self.withCatalogue(["1151", "1142", "1141"], storedPick: "1142") {
            let viewModel = ClassTableViewModel()

            Defaults[.classTableSelectedSemester] = nil
            viewModel.reloadFromCache()

            #expect(viewModel.currentSemester == "1151")
        }
    }
}
