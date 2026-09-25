#if os(iOS)
import Foundation

/// Fixtures that must contain literal separator/control/non-ASCII bytes for the owned-deleted
/// folder-name tests, kept isolated from the main test double file.
enum MailStoreTestFixtures {
    /// Contains `|`, `/`, U+001F (unit separator) and non-ASCII text — none of these may be
    /// mistaken for a key-joining separator by the owned-deleted store.
    static let folderWithArbitraryCharacters = "a|b/c\u{001F}d日本語"
}
#endif
