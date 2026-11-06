#if os(iOS)
import Foundation

nonisolated enum MailRecipientSuggestions {
    struct Contact: Equatable, Sendable {
        var address: MailAddress
        var score: Double
    }

    static let shown = 5
    private static let skippedRoles: [MailFolderRole] = [.drafts, .junk, .trash]
    private static let halfLife: TimeInterval = 30 * 24 * 60 * 60
    private static let writtenTo = 2.0
    private static let heardFrom = 1.0
    private static let undated = 0.001
    private static let noReply = try! NSRegularExpression(pattern: "^(no|do[-_.]?not)[-_.]?reply", options: .caseInsensitive)

    static func contacts(in pages: [MailFolderPage], own: String, roles: [MailFolderRole: String], now: Date) -> [Contact] {
        let cached = MailFolderMap.resolve(available: pages.map(\.folder))
        let skipped = Set(skippedRoles.flatMap { [roles[$0], cached[$0]].compactMap { $0 } })
        struct Tally {
            var address: MailAddress
            var at: Date? = nil
            var namedAt: Date? = nil
            var score = 0.0
        }
        let own = own.lowercased()
        var tallies: [String: Tally] = [:]
        for page in pages where !skipped.contains(page.folder) {
            for mail in page.summaries where !mail.isDeleted {
                let written = mail.fromAddress?.lowercased() == own
                let people = written
                    ? ((mail.to ?? []) + (mail.cc ?? [])).flatMap(MailAddress.parseList)
                    : mail.fromAddress.map { [MailAddress(name: mail.fromName, address: $0)] } ?? []
                let at = mail.date ?? mail.arrivedAt
                let weight = (written ? writtenTo : heardFrom) * decay(since: at, now: now)
                var counted = Set<String>()
                for person in people {
                    let address = person.address.trimmingCharacters(in: .whitespaces)
                    let key = address.lowercased()
                    guard MailRecipients.sendableAddress(address) != nil, key != own, !isNoReply(address),
                          counted.insert(key).inserted else { continue }
                    var tally = tallies[key] ?? Tally(address: MailAddress(name: nil, address: address))
                    tally.score += weight
                    if isLater(at, than: tally.at) {
                        tally.at = at
                        tally.address.address = address
                    }
                    if let name = person.name?.trimmingCharacters(in: .whitespaces).mailNonEmpty,
                       tally.namedAt == nil || isLater(at, than: tally.namedAt) {
                        tally.namedAt = at
                        tally.address.name = name
                    }
                    tallies[key] = tally
                }
            }
        }
        return tallies.values
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.address.address.lowercased() < $1.address.address.lowercased() }
            .map { Contact(address: $0.address, score: $0.score) }
    }

    static func matching(_ contacts: [Contact], typed: String, taken: [String]) -> [MailAddress] {
        let query = typed.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let taken = Set(taken.map { $0.lowercased() })
        let found = contacts.map(\.address).filter { address in
            !taken.contains(address.address.lowercased())
                && (address.address.containsSearchWord(query) || address.name?.containsSearchWord(query) == true)
        }
        let starts = { (address: MailAddress) in
            ([address.address] + (address.name ?? "").split(separator: " ").map(String.init))
                .contains { $0.range(of: query, options: [.caseInsensitive, .widthInsensitive, .anchored]) != nil }
        }
        return Array((found.filter(starts) + found.filter { !starts($0) }).prefix(shown))
    }

    private static func decay(since at: Date?, now: Date) -> Double {
        guard let at else { return undated }
        return pow(0.5, max(0, now.timeIntervalSince(at)) / halfLife)
    }

    private static func isLater(_ at: Date?, than other: Date?) -> Bool {
        guard let at else { return false }
        return other.map { at > $0 } ?? true
    }

    private static func isNoReply(_ address: String) -> Bool {
        let local = String(address.prefix { $0 != "@" })
        return noReply.firstMatch(in: local, range: NSRange(local.startIndex..., in: local)) != nil
    }
}
#endif
