import Defaults
import Foundation

/// One-shot migration: renames any persisted "待辦作業" section title to "作業".
///
/// Context: The `homeSectionLayoutData` Defaults key stores an array of
/// `HomeSection` structs as JSON. When this migration runs, it reads that
/// array, patches the `upcomingAssignments` entry's title if it still says
/// "待辦作業", writes it back, and sets a completion flag so it never runs
/// again.
enum HomeSectionTitleMigration {
    private static let doneKey = "HomeSectionTitleMigration.v1.done"

    static func runIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: doneKey) }
        migrateSectionTitles()
    }

    private static func migrateSectionTitles() {
        guard let data = Defaults[.homeSectionLayoutData],
              let sections = try? JSONDecoder().decode([HomeSection].self, from: data) else {
            return
        }

        let patchedSections = sections.map { section in
            guard section.type == .upcomingAssignments, section.title == "待辦作業" else {
                return section
            }

            var patchedSection = section
            patchedSection.title = HomeSection.HomeSectionType.upcomingAssignments.defaultTitle
            return patchedSection
        }

        guard patchedSections != sections,
              let patchedData = try? JSONEncoder().encode(patchedSections) else {
            return
        }

        Defaults[.homeSectionLayoutData] = patchedData
    }
}
