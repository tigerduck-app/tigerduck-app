import Foundation

nonisolated extension String {
    /// Whether `word` appears in the string, ignoring case and character width, so that a
    /// full-width or upper-case query finds half-width or lower-case text.
    func containsSearchWord(_ word: some StringProtocol) -> Bool {
        range(of: word, options: [.caseInsensitive, .widthInsensitive]) != nil
    }
}
