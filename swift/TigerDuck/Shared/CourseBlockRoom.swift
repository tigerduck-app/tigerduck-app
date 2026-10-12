import Foundation

/// The room of one block of a course's periods, read from its per-slot map (`"weekday-period"`
/// to room). A course's flat `classroom` joins every room it meets in, which is only the
/// fallback for a block the map has no room for. Compiled into the widget extension as well,
/// which has no `SDCourse`, so it works on the map and strings alone.
nonisolated enum CourseBlockRoom {
    /// The distinct rooms of `periods` on `weekday`, in period order, or `fallback` when the
    /// map holds none of them.
    static func room(
        weekday: Int,
        periods: [String],
        map: [String: String],
        fallback: String
    ) -> String {
        var seen = Set<String>()
        var rooms: [String] = []
        for period in periods {
            guard let raw = map["\(weekday)-\(period)"] else { continue }
            for part in split(raw) where seen.insert(part).inserted {
                rooms.append(part)
            }
        }
        return rooms.isEmpty ? fallback : rooms.joined(separator: ", ")
    }

    static func split(_ raw: String) -> [String] {
        raw.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static let separators = CharacterSet(charactersIn: "、，,")
}
