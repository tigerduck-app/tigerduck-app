import Foundation

/// Shared ISO-8601 decoding strategy that accepts both
/// `2026-04-22T02:10:00.123+00:00` and `2026-04-22T02:10:00+00:00`.
///
/// The Python backend emits `datetime.isoformat()` which may include
/// fractional seconds depending on the source timestamp. Keeping this
/// in one place means every JSON-decoding HTTP client in the app
/// consistently accepts both shapes.
extension JSONDecoder.DateDecodingStrategy {
    static var iso8601WithFractionalSecondsFallback: Self {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = TigerDuckDateFormatters.withFractional.date(from: raw) {
                return date
            }
            if let date = TigerDuckDateFormatters.withoutFractional.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognised date: \(raw)"
            )
        }
    }
}

enum TigerDuckDateFormatters {
    static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let withoutFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
