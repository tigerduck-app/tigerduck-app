import Foundation

/// One localized "What's new" summary block, decoded from `whatsnew.json`.
/// The summary is the last page of the What's New flow — the Apple-style
/// list of a release's highlights. Feature pages that precede it are
/// defined in code (``WhatsNewCatalog``), not here.
///
/// ```json
/// {
///   "2.3.0": {
///     "zh-TW": { "title": "...", "items": [{ "symbol": "...", "title": "...", "body": "..." }] },
///     "en":    { "title": "...", "items": [{ "symbol": "...", "title": "...", "body": "..." }] }
///   }
/// }
/// ```
///
/// Top-level keys are `CFBundleShortVersionString` values (iOS marketing
/// version, e.g. `"2.3.0"`). Each entry holds a per-locale map; the
/// repository picks the locale that best matches the resolved app
/// language tag, falling back to `en`.
///
/// Entries written before the item rows existed carry `highlights` — a
/// plain list of sentences — instead of `items`. Both still decode;
/// `items` wins when an entry has both.
///
/// Fields are optional defensively — a release with no JSON edit should
/// silently skip the summary instead of crashing on decode. The
/// repository's selector treats an entry with missing/blank `title` or
/// no usable rows as absent.
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
