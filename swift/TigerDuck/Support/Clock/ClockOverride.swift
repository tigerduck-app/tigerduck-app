import Foundation

nonisolated struct ClockOverride: Codable, Equatable, Sendable {
    let instant: Date
    let frozen: Bool
    let savedAtReal: Date

    static func decode(snapshotJSON json: String?) -> ClockOverride? {
        guard let data = json?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ClockOverride.self, from: data)
    }
}
