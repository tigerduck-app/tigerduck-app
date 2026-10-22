import Foundation

nonisolated enum CourseBlockRoom {
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
