import Foundation

/// A row that a search found, named by where it sits and what it is called.
nonisolated struct SettingsSearchResult: Identifiable, Equatable {
    let row: SettingsRow
    let path: [String]

    var id: SettingsRow { row }
    var text: String { path.joined(separator: " › ") }
}

nonisolated enum SettingsSearch {
    /// The shown rows whose title or section or page name holds every word of `query`, in the
    /// app's language, ignoring case and width.
    static func results(for query: String, in state: SettingsState) -> [SettingsSearchResult] {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return [] }
        return SettingsRow.allCases.compactMap { row in
            guard row.isShown(in: state) else { return nil }
            let path = path(of: row)
            guard words.allSatisfy({ word in path.contains { matches($0, word) } }) else { return nil }
            return SettingsSearchResult(row: row, path: path)
        }
    }

    static func path(of row: SettingsRow) -> [String] {
        let names = [row.place.titleKey.map { String(localized: $0) }, row.label].compactMap { $0 }
        return names.first == names.last ? [row.label] : names
    }

    static func matches(_ text: String, _ word: some StringProtocol) -> Bool {
        text.range(of: word, options: [.caseInsensitive, .widthInsensitive]) != nil
    }
}
