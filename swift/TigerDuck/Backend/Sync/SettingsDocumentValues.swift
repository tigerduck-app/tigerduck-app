import Foundation

private nonisolated struct WholeNumberElement: Decodable {
    let value: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try? container.decode(Int.self)
    }
}

/// A settings document's list of whole numbers. A bad element is dropped, not the list, as the
/// backend's `_numbers` (`server/push/reminders.py`) and Android's `asValidatedIntListOrNull` do:
/// all three read the notification document's `[30, "15"]` as the full set `[30]`, not as a reason
/// to fall back to `reminder_offsets_hours`. The backend delivers the reminders, so reading it
/// differently would give two devices on one account different reminders.
nonisolated func wholeNumberList<Key: CodingKey>(
    in container: KeyedDecodingContainer<Key>,
    forKey key: Key
) -> [Int]? {
    let decoded = try? container.decodeIfPresent([WholeNumberElement].self, forKey: key)
    guard let elements = decoded.flatMap({ $0 }) else { return nil }
    return elements.compactMap(\.value)
}

nonisolated extension SettingsDocument {
    /// The namespace's document as a full sync's snapshot lists it in `settings_documents`; nil when
    /// the snapshot cannot say, and the caller reads the document instead.
    static func inSnapshot(_ json: [String: Any], namespace: String) -> SettingsDocument? {
        guard let entries = json["settings_documents"] as? [[String: Any]] else { return nil }
        guard let entry = entries.first(where: { $0["namespace"] as? String == namespace }) else { return .neverWritten }
        guard let revision = entry["revision"] as? Int,
              let object = entry["document"], JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object)
        else { return nil }
        return .stored(document: data, revision: revision)
    }

    /// `updates` spliced over `existing` key by key and recursively, so that keys this build does not
    /// know survive; an array is replaced whole (docs/decisions/0002-notification-settings-json-merge.md).
    static func merging(_ updates: [String: Any], into existing: [String: Any]) -> [String: Any] {
        var merged = existing
        for (key, value) in updates {
            if let update = value as? [String: Any],
               let current = merged[key] as? [String: Any] {
                merged[key] = merging(update, into: current)
            } else {
                merged[key] = value
            }
        }
        return merged
    }

    static func object(from data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}
