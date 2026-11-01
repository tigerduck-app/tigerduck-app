import Foundation

struct BulletinFilter {
    var orgs: Set<String> = []
    var tags: Set<String> = []
    var searchText = ""

    var isActive: Bool { !orgs.isEmpty || !tags.isEmpty || !searchText.isEmpty }

    func apply(to items: [BulletinAPI.BulletinSummary]) -> [BulletinAPI.BulletinSummary] {
        var result = items
        if !orgs.isEmpty {
            result = result.filter { row in
                guard let org = row.canonicalOrg else { return false }
                return orgs.contains(org)
            }
        }
        if !tags.isEmpty {
            result = result.filter { row in
                !Set(row.contentTags).isDisjoint(with: tags)
            }
        }
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            result = result.filter { row in
                row.displayTitle.localizedCaseInsensitiveContains(trimmed) ||
                row.title.localizedCaseInsensitiveContains(trimmed) ||
                (row.summary?.localizedCaseInsensitiveContains(trimmed) ?? false)
            }
        }
        return result
    }
}
