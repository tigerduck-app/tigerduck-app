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
