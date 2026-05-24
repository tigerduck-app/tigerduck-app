#if os(iOS)
import Foundation

/// One localized "What's new" block, decoded from `whatsnew.json`. The
/// JSON shape mirrors the Android port (`assets/whatsnew.json`):
///
/// ```json
/// {
///   "1.7.0": {
///     "zh-TW": { "title": "...", "highlights": ["...", "..."] },
///     "en":    { "title": "...", "highlights": ["...", "..."] }
///   }
/// }
/// ```
///
/// Top-level keys are `CFBundleShortVersionString` values (iOS marketing
/// version, e.g. `"1.7.0"`). Each entry holds a per-locale map; the
/// repository picks the locale that best matches the resolved app
/// language tag, falling back to `en`.
///
/// Fields are optional defensively — a release with no JSON edit should
/// silently skip the prompt instead of crashing on decode. The
/// repository's selector treats an entry with missing/blank `title` or
/// empty `highlights` as absent.
struct WhatsNewEntry: Decodable, Equatable {
    let title: String?
    let highlights: [String]?
}
#endif
