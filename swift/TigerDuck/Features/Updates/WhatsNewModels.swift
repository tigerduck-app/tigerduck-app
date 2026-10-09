import Foundation

/// One localized summary block from `whatsnew.json`: the Apple-style list
/// of a release's highlights that ends the What's New flow, after the
/// feature pages in ``WhatsNewCatalog``. The file maps each marketing
/// version (`CFBundleShortVersionString`) to a per-locale map of these.
/// Older entries carry `highlights`, plain sentences, instead of `items`; both
/// decode, and `items` wins when both exist. Fields are optional so a release
/// with no JSON edit skips the summary instead of failing to decode. The
/// repository drops an entry with a missing or blank `title` or no usable rows.
struct WhatsNewEntry: Decodable, Equatable {
    let title: String?
    let items: [WhatsNewItem]?
    let highlights: [String]?
}

/// One row of the summary list: an SF Symbol, a short headline and a
/// line or two of detail. Every field is optional on disk; a row with
/// neither `title` nor `body` is dropped, and a row without `symbol`
/// renders with a plain bullet.
struct WhatsNewItem: Decodable, Equatable {
    let symbol: String?
    let title: String?
    let body: String?
}
