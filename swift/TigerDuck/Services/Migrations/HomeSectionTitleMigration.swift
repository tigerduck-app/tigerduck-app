import Defaults
import Foundation

/// One-shot migration: renames a persisted `upcomingAssignments` section title still set to the
/// old Chinese label ("To-do assignments", the literal below) to its `defaultTitle`.
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
